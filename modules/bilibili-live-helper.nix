{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.bilibiliLiveHelper;
  package = if cfg.package == null then pkgs.emptyDirectory else cfg.package;
  configFile =
    if cfg.configFile == null then
      pkgs.writeText "empty-bilibili-live-helper-config.yaml" ""
    else
      cfg.configFile;
  secret = config.sops.secrets."bilibili-live-helper/access_key";
  healthMonitor = pkgs.writeShellApplication {
    name = "bilibili-live-helper-health-monitor";
    runtimeInputs = [
      package
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      state_directory=/var/lib/bilibili-live-helper-health
      marker="$state_directory/alerted"
      endpoint=http://127.0.0.1:2586/inbox
      healthcheck=${package}/bin/bilibili-live-helper-healthcheck

      if message="$("$healthcheck" 2>&1)"; then
        if [ -e "$marker" ]; then
          if printf '%s' 'Bilibili Live Helper polling recovered.' | \
            curl --fail --silent --show-error --max-time 10 \
              -H 'Title: Bilibili Live Helper recovered' \
              -H 'Tags: white_check_mark' \
              --data-binary @- "$endpoint"; then
            rm -f "$marker"
          fi
        fi
      else
        echo "Bilibili Live Helper health check failed: $message" >&2
        if [ ! -e "$marker" ]; then
          if printf '%s' "$message" | \
            curl --fail --silent --show-error --max-time 10 \
              -H 'Title: Bilibili Live Helper polling failed' \
              -H 'Tags: warning' \
              --data-binary @- "$endpoint"; then
            touch "$marker"
          fi
        fi
      fi
    '';
  };
in
{
  options.ssvgg.bilibiliLiveHelper = {
    enable = lib.mkEnableOption "the Bilibili live task runner";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "The pinned Bilibili Live Helper package.";
    };

    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "The public Bilibili Live Helper YAML configuration.";
    };
    accessKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing the access key for this machine.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "ssvgg.bilibiliLiveHelper.package must be set when the service is enabled";
      }
      {
        assertion = cfg.configFile != null;
        message = "ssvgg.bilibiliLiveHelper.configFile must be set when the service is enabled";
      }
    ];

    sops.secrets."bilibili-live-helper/access_key" = {
      sopsFile = cfg.accessKeyFile;
      key = "data";
      restartUnits = [ "bilibili-live-helper.service" ];
    };

    environment.etc."bilibili-live-helper/config.yaml".source = configFile;

    systemd.services.bilibili-live-helper = {
      description = "Bilibili Live Helper";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "ntfy-sh.service"
      ];
      serviceConfig = {
        Type = "exec";
        LoadCredential = "access_key:${secret.path}";
        Environment = [
          "BILIBILI_LIVE_HELPER_CONFIG=/etc/bilibili-live-helper/config.yaml"
          "BILIBILI_LIVE_HELPER_ACCESS_KEY_FILE=%d/access_key"
          "BILIBILI_LIVE_HELPER_STATE=/var/lib/bilibili-live-helper/state.json"
        ];
        ExecStartPre = "${package}/bin/bilibili-live-helper-check-config";
        ExecStart = "${package}/bin/bilibili-live-helper";
        DynamicUser = true;
        StateDirectory = "bilibili-live-helper";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStopSec = "30s";
        MemoryMax = "256M";
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
          "AF_INET6"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.bilibili-live-helper-health = {
      description = "Bilibili Live Helper business health monitor";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "ntfy-sh.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "BILIBILI_LIVE_HELPER_CONFIG=/etc/bilibili-live-helper/config.yaml"
          "BILIBILI_LIVE_HELPER_STATE=/var/lib/bilibili-live-helper/state.json"
        ];
        ExecStart = "${healthMonitor}/bin/bilibili-live-helper-health-monitor";
        StateDirectory = "bilibili-live-helper-health";
        StateDirectoryMode = "0700";
        UMask = "0077";
        MemoryMax = "64M";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    systemd.timers.bilibili-live-helper-health = {
      description = "Check Bilibili Live Helper polling freshness";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "7m";
        OnUnitActiveSec = "2m";
        Persistent = true;
        Unit = "bilibili-live-helper-health.service";
      };
    };
  };
}
