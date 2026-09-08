{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.ntfy;
in
{
  options.ssvgg.ntfy = {
    enable = lib.mkEnableOption "an anonymous ntfy topic";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "ntfy.example.com";
      description = "Public hostname for the ntfy service.";
    };
    topic = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]{1,64}";
      default = "inbox";
      description = "Anonymous topic granted read/write access.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.ssvgg.web.enable;
        message = "ssvgg.ntfy requires ssvgg.web.enable";
      }
    ];

    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://${cfg.domain}";
        listen-http = "127.0.0.1:2586";
        behind-proxy = true;
        upstream-base-url = "https://ntfy.sh";

        auth-default-access = "deny-all";
        enable-login = false;
        enable-signup = false;

        cache-duration = "30d";
        message-size-limit = "4K";
        attachment-file-size-limit = "1K";
        attachment-total-size-limit = "1M";
        attachment-expiry-duration = "1h";
      };
    };

    # Keep only the public inbox open while all other topics remain denied.
    systemd.services.ntfy-sh = {
      # ntfy creates auth-file on its first start, so this must run afterwards.
      postStart = ''
        for _ in $(seq 1 20); do
          if [ -e /var/lib/ntfy-sh/user.db ]; then
            ${pkgs.ntfy-sh}/bin/ntfy access --config /etc/ntfy/server.yml everyone ${lib.escapeShellArg cfg.topic} rw
            exit 0
          fi
          sleep 0.5
        done
        echo "ntfy auth database was not created" >&2
        exit 1
      '';
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
        MemoryMax = "512M";
      };
    };

    services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
      reverse_proxy 127.0.0.1:2586
    '';
  };
}
