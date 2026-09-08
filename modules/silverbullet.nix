{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.silverbullet;
  source = pkgs.fetchzip {
    url = "https://github.com/silverbulletmd/silverbullet/releases/download/2.10.0/silverbullet-server-linux-x86_64.zip";
    hash = "sha256-8qxY7V9DwWCqbrNJsj8whcns5S/KpgEGodwPcIyQNS0=";
    stripRoot = false;
  };
  silverbullet = pkgs.runCommand "silverbullet-2.10.0" { } ''
    install -Dm755 ${source}/silverbullet "$out/bin/silverbullet"
  '';
  healthMonitor = pkgs.writeShellApplication {
    name = "silverbullet-health-monitor";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
    ];
    text = ''
      state_directory=/var/lib/silverbullet-health
      marker="$state_directory/alerted"
      health_endpoint=http://127.0.0.1:3000/.ping
      ntfy_endpoint=${lib.escapeShellArg cfg.ntfyEndpoint}

      if curl --fail --silent --show-error --max-time 10 "$health_endpoint" >/dev/null; then
        if [ -e "$marker" ]; then
          if printf '%s' 'SilverBullet recovered.' | \
            curl --fail --silent --show-error --max-time 10 \
              -H 'Title: SilverBullet recovered' \
              -H 'Tags: white_check_mark' \
              --data-binary @- "$ntfy_endpoint"; then
            rm -f "$marker"
          fi
        fi
      else
        echo 'SilverBullet health check failed' >&2
        if [ ! -e "$marker" ]; then
          if printf '%s' 'The SilverBullet health endpoint is unavailable.' | \
            curl --fail --silent --show-error --max-time 10 \
              -H 'Title: SilverBullet unavailable' \
              -H 'Tags: warning' \
              --data-binary @- "$ntfy_endpoint"; then
            touch "$marker"
          fi
        fi
      fi
    '';
  };
in
{
  options.ssvgg.silverbullet = {
    enable = lib.mkEnableOption "an anonymous public SilverBullet space";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "notes.example.com";
      description = "Public hostname for SilverBullet.";
    };
    ntfyEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:2586/inbox";
      description = "ntfy endpoint used by the health monitor.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.ssvgg.web.enable;
        message = "ssvgg.silverbullet requires ssvgg.web.enable";
      }
    ];

    systemd.services.silverbullet = {
      description = "SilverBullet anonymous public knowledge base";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "exec";
        Environment = [
          "SB_FOLDER=/var/lib/silverbullet/space"
          "SB_HOSTNAME=127.0.0.1"
          "SB_PORT=3000"
          "SB_RUNTIME_API=0"
          "SB_SHELL_BACKEND=off"
        ];
        ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p -m 0700 /var/lib/silverbullet/space";
        ExecStart = "${silverbullet}/bin/silverbullet";
        DynamicUser = true;
        StateDirectory = "silverbullet";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "5s";
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
          "AF_INET6"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.silverbullet-health = {
      description = "SilverBullet health monitor";
      after = [
        "silverbullet.service"
        "ntfy-sh.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${healthMonitor}/bin/silverbullet-health-monitor";
        StateDirectory = "silverbullet-health";
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

    systemd.timers.silverbullet-health = {
      description = "Check SilverBullet availability";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5m";
        OnUnitActiveSec = "5m";
        Persistent = true;
        Unit = "silverbullet-health.service";
      };
    };

    services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
      reverse_proxy 127.0.0.1:3000
    '';
  };
}
