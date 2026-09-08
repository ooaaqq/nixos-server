{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.bililiveRecorder;
  credentials = config.sops.secrets."bilibili/cookies";
  biliup = pkgs.callPackage ../packages/biliup.nix { };
  recorderConfig = pkgs.writeText "bililive-recorder-config.json" (
    builtins.toJSON {
      version = 3;
      global = {
        RecordMode = {
          HasValue = true;
          Value = 0;
        };
        CuttingMode = {
          HasValue = true;
          Value = 1;
        };
        CuttingNumber = {
          HasValue = true;
          Value = 60;
        };
        RecordDanmaku = {
          HasValue = true;
          Value = true;
        };
        RecordDanmakuRaw = {
          HasValue = true;
          Value = true;
        };
        RecordDanmakuGift = {
          HasValue = true;
          Value = true;
        };
        SaveStreamCover = {
          HasValue = true;
          Value = true;
        };
        RecordingQuality = {
          HasValue = true;
          Value = "avc30000,hevc30000,avc25000,hevc25000,avc20000,hevc20000,avc15000,hevc15000,avc10000,hevc10000,avc400,hevc400,avc250,hevc250";
        };
        FileNameRecordTemplate = {
          HasValue = true;
          Value = ''{{ roomId }}-{{ name }}/{{ "now" | time_zone: "Asia/Shanghai" | format_date: "yyyyMMdd-HHmmss" }}-{{ qn | format_qn }}-{{ title }}.flv'';
        };
        FlvProcessorSplitOnScriptTag = {
          HasValue = true;
          Value = true;
        };
        NetworkTransportAllowedAddressFamily = {
          HasValue = true;
          Value = 1;
        };
        TimingCheckInterval = {
          HasValue = true;
          Value = 30;
        };
        WebHookUrlsV2 = {
          HasValue = true;
          Value = "http://127.0.0.1:22357/webhook";
        };
        Cookie = {
          HasValue = true;
          Value = "";
        };
      };
      rooms = map (roomId: {
        RoomId = {
          HasValue = true;
          Value = roomId;
        };
        AutoRecord = {
          HasValue = true;
          Value = true;
        };
      }) cfg.roomIds;
    }
  );
  uploadMetadata = pkgs.writeText "biliup-upload-metadata.json" (
    builtins.toJSON {
      title = cfg.uploadTitle;
      description = cfg.uploadDescription;
      tags = cfg.uploadTags;
    }
  );
  prepareConfig = pkgs.writeShellApplication {
    name = "bililive-recorder-prepare-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      install -d -m 0700 "$STATE_DIRECTORY/recordings" "$STATE_DIRECTORY/logs"
      cookie=$(jq --exit-status --raw-output \
        '[.cookie_info.cookies[] | select(
          (.name | type == "string") and (.value | type == "string")
        ) | "\(.name)=\(.value)"] | if length > 0 then join("; ") else error("empty cookie set") end' \
        "$CREDENTIALS_DIRECTORY/cookies.json")
      jq --arg cookie "$cookie" '.global.Cookie.Value = $cookie' \
        ${recorderConfig} > "$RUNTIME_DIRECTORY/config.json.new"
      chmod 0600 "$RUNTIME_DIRECTORY/config.json.new"
      mv "$RUNTIME_DIRECTORY/config.json.new" "$RUNTIME_DIRECTORY/config.json"
    '';
  };
  prepareUploaderCredential = pkgs.writeShellApplication {
    name = "bililive-recorder-prepare-uploader-credential";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      source="$CREDENTIALS_DIRECTORY/cookies.json"
      destination="$STATE_DIRECTORY/cookies.json"
      marker="$STATE_DIRECTORY/cookies.source.sha256"
      jq --exit-status \
        '.cookie_info.cookies | type == "array" and length > 0' \
        "$source" >/dev/null
      source_hash=$(sha256sum "$source" | cut -d ' ' -f 1)
      if [[ ! -s "$destination" ]] || [[ ! -f "$marker" ]] || [[ "$(<"$marker")" != "$source_hash" ]]; then
        install -m 0600 "$source" "$destination"
        printf '%s\n' "$source_hash" > "$marker"
      fi
    '';
  };
  cleanup = pkgs.writeShellApplication {
    name = "bililive-recorder-cleanup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      recording_dir=/var/lib/bililive-recorder/recordings
      minimum_free_bytes=$((${toString cfg.minimumFreeGiB} * 1024 * 1024 * 1024))
      maximum_age_minutes=$((${toString cfg.maximumAgeDays} * 24 * 60))
      install -d -m 0700 "$recording_dir"

      remove_bundle() {
        local flv="$1"
        local base="''${flv%.flv}"
        rm -f -- "$flv" "$base.xml" "$base.cover.jpg"
      }

      while IFS= read -r -d "" flv; do
        remove_bundle "$flv"
      done < <(find "$recording_dir" -type f -name '*.flv' \
        -mmin "+$maximum_age_minutes" -print0)

      while IFS= read -r -d "" entry; do
        available=$(df --output=avail -B1 "$recording_dir" | tail -n 1 | tr -d ' ')
        if ((available >= minimum_free_bytes)); then
          break
        fi
        remove_bundle "''${entry#* }"
      done < <(find "$recording_dir" -type f -name '*.flv' -mmin +10 \
        -printf '%T@ %p\0' | sort -z -n)

      available=$(df --output=avail -B1 "$recording_dir" | tail -n 1 | tr -d ' ')
      if ((available < minimum_free_bytes)); then
        echo "recording disk remains below the free-space target; no closed segment is safe to remove" >&2
      fi
    '';
  };
  notifierScript = ../packages/bililive-recorder-notifier.py;
in
{
  options.ssvgg.bililiveRecorder = {
    enable = lib.mkEnableOption "BililiveRecorder with local ntfy event delivery";

    roomIds = lib.mkOption {
      type = lib.types.listOf lib.types.ints.positive;
      default = [ ];
      description = "Bilibili live rooms to monitor and record concurrently.";
    };

    node = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]{1,24}";
      description = "Short node label included in notifications.";
    };

    credentialFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing the shared biliup cookies.json document.";
    };

    upload = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Upload completed sessions to Bilibili as private videos.";
    };

    uploadTitle = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "{name} 直播回放 {title} {date}";
      description = "Private upload title template; supports name, title, date, room_id, and node placeholders.";
    };

    uploadDescription = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = ''
        直播间：https://live.bilibili.com/{room_id}
        由 {node} 自动录制上传。
      '';
      description = "Private upload description template with the same placeholders as uploadTitle.";
    };

    uploadTags = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [
        "录播"
        "直播回放"
      ];
      description = "Tags attached to private uploads.";
    };

    ntfyServer = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:2586";
      description = "ntfy JSON publish endpoint.";
    };

    ntfyTopic = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]{1,64}";
      default = "inbox";
      description = "ntfy topic receiving recorder notifications.";
    };

    minimumFreeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Delete oldest closed recording segments below this free-space target.";
    };

    maximumAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Maximum age of closed recording segments.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.roomIds != [ ] && lib.length cfg.roomIds == lib.length (lib.unique cfg.roomIds);
        message = "ssvgg.bililiveRecorder.roomIds must be non-empty and contain no duplicates";
      }
      {
        assertion = cfg.uploadTags != [ ] && lib.all (tag: !(lib.hasInfix "," tag)) cfg.uploadTags;
        message = "ssvgg.bililiveRecorder.uploadTags must be non-empty and contain no commas";
      }
    ];

    users.groups.bililive-recorder = { };
    users.users.bililive-recorder = {
      isSystemUser = true;
      group = "bililive-recorder";
    };

    sops.secrets."bilibili/cookies" = {
      sopsFile = cfg.credentialFile;
      key = "data";
      restartUnits = [
        "bililive-recorder.service"
        "bililive-recorder-notifier.service"
      ];
    };

    systemd.services.bililive-recorder-notifier = {
      description = "BililiveRecorder webhook and ntfy notifier";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.concatStringsSep " " (
          [
            "${pkgs.python3}/bin/python3"
            "${notifierScript}"
            "--node ${lib.escapeShellArg cfg.node}"
            "--ntfy-server ${lib.escapeShellArg cfg.ntfyServer}"
            "--ntfy-topic ${lib.escapeShellArg cfg.ntfyTopic}"
            "--state /var/lib/bililive-recorder-notifier/state.json"
          ]
          ++ map (roomId: "--room-id ${toString roomId}") cfg.roomIds
          ++ lib.optionals cfg.upload [
            "--uploader ${biliup}/bin/biliup"
            "--uploader-cookie /var/lib/bililive-recorder-notifier/cookies.json"
            "--recording-root /var/lib/bililive-recorder/recordings"
            "--upload-line alia"
            "--upload-metadata ${uploadMetadata}"
          ]
        );
        LoadCredential = lib.mkIf cfg.upload "cookies.json:${credentials.path}";
        ExecStartPre = lib.mkIf cfg.upload "${prepareUploaderCredential}/bin/bililive-recorder-prepare-uploader-credential";
        Environment = lib.mkIf cfg.upload "XDG_DATA_HOME=/var/lib/bililive-recorder-notifier";
        WorkingDirectory = lib.mkIf cfg.upload "/var/lib/bililive-recorder-notifier";
        User = "bililive-recorder";
        Group = "bililive-recorder";
        StateDirectory = "bililive-recorder-notifier";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "15s";
        MemoryMax = if cfg.upload then "512M" else "96M";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.bililive-recorder = {
      description = "BililiveRecorder rooms ${lib.concatMapStringsSep "," toString cfg.roomIds}";
      wantedBy = [ "multi-user.target" ];
      requires = [ "bililive-recorder-notifier.service" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "bililive-recorder-notifier.service"
      ];
      serviceConfig = {
        Type = "exec";
        LoadCredential = "cookies.json:${credentials.path}";
        Environment = "BILILIVERECORDER_LOG_FILE_PATH=/var/lib/bililive-recorder/logs/bilirec.txt";
        ExecStartPre = "${prepareConfig}/bin/bililive-recorder-prepare-config";
        ExecStart = "${pkgs.bililiverecorder}/bin/BililiveRecorder run /var/lib/bililive-recorder/recordings --config-override /run/bililive-recorder/config.json --http-bind http://127.0.0.1:22356";
        User = "bililive-recorder";
        Group = "bililive-recorder";
        StateDirectory = "bililive-recorder";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "bililive-recorder";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "15s";
        TimeoutStopSec = "30s";
        MemoryMax = "512M";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.bililive-recorder-cleanup = {
      description = "Prune closed BililiveRecorder segments";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cleanup}/bin/bililive-recorder-cleanup";
        User = "bililive-recorder";
        Group = "bililive-recorder";
        StateDirectory = "bililive-recorder";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };

    systemd.timers.bililive-recorder-cleanup = {
      description = "Periodically prune closed BililiveRecorder segments";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15m";
        OnUnitActiveSec = "10m";
        Persistent = true;
        Unit = "bililive-recorder-cleanup.service";
      };
    };
  };
}
