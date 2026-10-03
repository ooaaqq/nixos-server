{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.bililiveRecorder;
  common = import ./bililive-recorder-common.nix {
    inherit config lib pkgs;
    recorderCfg = cfg;
  };
in
{
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
      {
        assertion = !cfg.upload || cfg.uploadCredentialFile != null;
        message = "ssvgg.bililiveRecorder.uploadCredentialFile is required when upload = true";
      }
    ];

    users.groups.bililive-recorder = { };
    users.users.bililive-recorder = {
      isSystemUser = true;
      group = "bililive-recorder";
    };

    sops.secrets."bilibili/recording-cookies" = {
      sopsFile = cfg.recordingCredentialFile;
      key = "data";
      restartUnits = [
        "bililive-recorder.service"
      ];
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
        LoadCredential = "cookies.json:${common.recordingCredentials.path}";
        Environment = "BILILIVERECORDER_LOG_FILE_PATH=/var/lib/bililive-recorder/logs/bilirec.txt";
        ExecStartPre = "${common.prepareConfig}/bin/bililive-recorder-prepare-config";
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
        ExecStart = "${common.cleanup}/bin/bililive-recorder-cleanup";
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
