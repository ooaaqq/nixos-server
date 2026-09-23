{
  config,
  lib,
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
        "auth-access" = [ "everyone:inbox:rw" ];

        cache-duration = "30d";
        message-size-limit = "4K";
        attachment-file-size-limit = "1K";
        attachment-total-size-limit = "1M";
        attachment-expiry-duration = "1h";
      };
    };

    systemd.services.ntfy-sh = {
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
