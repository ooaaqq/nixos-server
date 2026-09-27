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
  danmakuFactory = pkgs.callPackage ../packages/danmaku-factory.nix { };
  monochromeEmojiFont = pkgs.callPackage ../packages/noto-emoji-mono.nix { };
  danmakuFonts = pkgs.runCommand "bililive-recorder-danmaku-fonts" { } ''
    mkdir -p "$out"
    ln -s "${pkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc" \
      "$out/NotoSansCJK-VF.otf.ttc"
    ln -s "${monochromeEmojiFont}/share/fonts/opentype/noto/NotoEmoji.otf" \
      "$out/NotoEmoji.otf"
  '';
  fontconfigFile = pkgs.makeFontsConf {
    fontDirectories = [ danmakuFonts ];
  };
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
      danmaku = {
        room_ids = cfg.danmaku.roomIds;
        settings = {
          scroll_time = cfg.danmaku.scrollTime;
          density = cfg.danmaku.density;
          font_size = cfg.danmaku.fontSize;
          font_name = cfg.danmaku.fontName;
          opacity = cfg.danmaku.opacity;
          outline = cfg.danmaku.outline;
          shadow = cfg.danmaku.shadow;
          show_usernames = cfg.danmaku.showUsernames;
          show_message_boxes = cfg.danmaku.showMessageBoxes;
          crf = cfg.danmaku.crf;
          max_rate_kbit = cfg.danmaku.maxRateKbit;
          buffer_size_kbit = cfg.danmaku.bufferSizeKbit;
          preset = cfg.danmaku.preset;
          threads = cfg.danmaku.threads;
        };
      };
      collection =
        if cfg.collection.roomIds == [ ] then
          null
        else
          {
            room_ids = cfg.collection.roomIds;
            season_title = cfg.collection.seasonTitle;
            section_title = cfg.collection.sectionTitle;
          };
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
        rm -f -- "$flv" "$base.xml" "$base.cover.jpg" \
          "$base-纯净版.flv" "$base-弹幕版.ass" "$base-弹幕版.partial.mp4" \
          "$base-弹幕版.mp4"
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

    danmaku = lib.mkOption {
      type = lib.types.submodule {
        options = {
          roomIds = lib.mkOption {
            type = lib.types.listOf lib.types.ints.positive;
            default = [ ];
            description = "Rooms whose uploads include source and burned-danmaku parts.";
          };

          scrollTime = lib.mkOption {
            type = lib.types.ints.positive;
            default = 12;
            description = "Seconds for scrolling danmaku to cross the screen.";
          };

          density = lib.mkOption {
            type = lib.types.int;
            default = -1;
            description = "DanmakuFactory density; -1 requests non-overlapping scrolling comments.";
          };

          fontSize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 32;
            description = "Danmaku font size in pixels.";
          };

          fontName = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "Noto Sans CJK SC";
            description = "Base font family used for danmaku.";
          };

          opacity = lib.mkOption {
            type = lib.types.ints.between 1 255;
            default = 255;
            description = "Opacity for ordinary danmaku, from 1 to 255.";
          };

          outline = lib.mkOption {
            type = lib.types.float;
            default = 0.8;
            description = "Thin text outline width in pixels.";
          };

          shadow = lib.mkOption {
            type = lib.types.ints.between 0 4;
            default = 0;
            description = "Danmaku shadow depth.";
          };

          showUsernames = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to include danmaku usernames.";
          };

          showMessageBoxes = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to render gifts, Super Chat, and guard message boxes.";
          };

          crf = lib.mkOption {
            type = lib.types.ints.between 0 51;
            default = 22;
            description = "x264 constant-rate-factor for burned-danmaku parts.";
          };

          maxRateKbit = lib.mkOption {
            type = lib.types.ints.positive;
            default = 18000;
            description = "Maximum x264 bitrate in kbit/s.";
          };

          bufferSizeKbit = lib.mkOption {
            type = lib.types.ints.positive;
            default = 36000;
            description = "x264 VBV buffer size in kbit/s.";
          };

          preset = lib.mkOption {
            type = lib.types.enum [
              "ultrafast"
              "superfast"
              "veryfast"
              "faster"
              "fast"
              "medium"
            ];
            default = "veryfast";
            description = "x264 speed and compression preset.";
          };

          threads = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "Maximum x264 worker threads per transcode.";
          };
        };
      };
      default = { };
      description = "Settings for burned-in danmaku uploads.";
    };

    collection = lib.mkOption {
      type = lib.types.submodule {
        options = {
          roomIds = lib.mkOption {
            type = lib.types.listOf lib.types.ints.positive;
            default = [ ];
            description = "Rooms whose uploaded archives should be added to a Bilibili collection.";
          };

          seasonTitle = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "露早录播";
            description = "Exact Bilibili collection title to match.";
          };

          sectionTitle = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "正片";
            description = "Exact section title within the collection.";
          };
        };
      };
      default = { };
      description = "Bilibili collection assignment after upload.";
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
      {
        assertion =
          lib.length cfg.danmaku.roomIds == lib.length (lib.unique cfg.danmaku.roomIds)
          && lib.all (roomId: lib.elem roomId cfg.roomIds) cfg.danmaku.roomIds;
        message = "ssvgg.bililiveRecorder.danmaku.roomIds must be unique configured recorder rooms";
      }
      {
        assertion = cfg.danmaku.roomIds == [ ] || cfg.upload;
        message = "ssvgg.bililiveRecorder.danmaku.roomIds requires upload = true";
      }
      {
        assertion =
          lib.length cfg.collection.roomIds == lib.length (lib.unique cfg.collection.roomIds)
          && lib.all (roomId: lib.elem roomId cfg.danmaku.roomIds) cfg.collection.roomIds;
        message = "ssvgg.bililiveRecorder.collection.roomIds must be unique rooms with danmaku uploads enabled";
      }
      {
        assertion = cfg.collection.roomIds == [ ] || cfg.upload;
        message = "ssvgg.bililiveRecorder.collection.roomIds requires upload = true";
      }
      {
        assertion = cfg.danmaku.outline >= 0.0 && cfg.danmaku.outline <= 4.0;
        message = "ssvgg.bililiveRecorder.danmaku.outline must be between 0 and 4";
      }
      {
        assertion = cfg.danmaku.bufferSizeKbit >= cfg.danmaku.maxRateKbit;
        message = "ssvgg.bililiveRecorder.danmaku.bufferSizeKbit must be at least maxRateKbit";
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
          ++ lib.optionals (cfg.danmaku.roomIds != [ ]) [
            "--danmaku-factory ${danmakuFactory}/bin/DanmakuFactory"
            "--ffmpeg ${pkgs.ffmpeg-headless}/bin/ffmpeg"
            "--ffprobe ${pkgs.ffmpeg-headless}/bin/ffprobe"
            "--fonts-directory ${danmakuFonts}"
          ]
        );
        LoadCredential = lib.mkIf cfg.upload "cookies.json:${credentials.path}";
        ExecStartPre = lib.mkIf cfg.upload "${prepareUploaderCredential}/bin/bililive-recorder-prepare-uploader-credential";
        Environment =
          lib.optionals cfg.upload [ "XDG_DATA_HOME=/var/lib/bililive-recorder-notifier" ]
          ++ lib.optionals (cfg.danmaku.roomIds != [ ]) [
            "FONTCONFIG_FILE=${fontconfigFile}"
            "XDG_CACHE_HOME=/var/lib/bililive-recorder-notifier/font-cache"
          ];
        WorkingDirectory = lib.mkIf cfg.upload "/var/lib/bililive-recorder-notifier";
        ReadWritePaths = lib.optionals (cfg.danmaku.roomIds != [ ]) [
          "/var/lib/bililive-recorder/recordings"
        ];
        User = "bililive-recorder";
        Group = "bililive-recorder";
        StateDirectory = "bililive-recorder-notifier";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "15s";
        MemoryMax = if cfg.upload then "2G" else "96M";
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
