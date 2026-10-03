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
