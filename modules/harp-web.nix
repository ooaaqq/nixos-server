{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.harpWeb;
  usersSecret = config.sops.secrets."harp-web/users";
  kaggleSecret = config.sops.secrets."harp-web/kaggle";
  prepareKaggle = pkgs.writeShellApplication {
    name = "harp-web-prepare-kaggle";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      jq --exit-status '(.username | type == "string") and (.access_token | type == "string") and (.refresh_token | type == "string")' "$1" >/dev/null
      install -d -m 0700 /var/lib/harp-web/kaggle
      install -m 0600 "$1" /var/lib/harp-web/kaggle/credentials.json
    '';
  };
in
{
  options.ssvgg.harpWeb = {
    enable = lib.mkEnableOption "HARP separation and conversion web service";
    package = lib.mkOption {
      type = lib.types.package;
      description = "harp-studio package";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "svc.ssvgg.com";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8766;
    };
    credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing users and Kaggle credentials";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.harp-web = { };
    users.users.harp-web = {
      isSystemUser = true;
      group = "harp-web";
      home = "/var/lib/harp-web";
    };
    sops.secrets."harp-web/users" = {
      sopsFile = cfg.credentialsFile;
      key = "users";
      owner = "harp-web";
      restartUnits = [ "harp-web.service" ];
    };
    sops.secrets."harp-web/kaggle" = {
      sopsFile = cfg.credentialsFile;
      key = "kaggle";
      owner = "harp-web";
      restartUnits = [ "harp-web.service" ];
    };
    systemd.services.harp-web = {
      description = "HARP separation and conversion web service";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        User = "harp-web";
        Group = "harp-web";
        WorkingDirectory = "/var/lib/harp-web";
        StateDirectory = "harp-web";
        LoadCredential = [
          "users.json:${usersSecret.path}"
          "kaggle.json:${kaggleSecret.path}"
        ];
        Environment = [
          "HARP_WEB_HOST=127.0.0.1"
          "HARP_WEB_PORT=${toString cfg.port}"
          "HARP_WEB_STATE=/var/lib/harp-web"
          "HARP_WEB_USERS_FILE=%d/users.json"
          "KAGGLE_CONFIG_DIR=/var/lib/harp-web/kaggle"
          "HOME=/var/lib/harp-web"
          "PATH=/run/current-system/sw/bin"
        ];
        ExecStartPre = "${prepareKaggle}/bin/harp-web-prepare-kaggle %d/kaggle.json";
        ExecStart = "${cfg.package}/bin/harp-web";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/harp-web" ];
      };
    };
    services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
      request_body { max_size 500MB }
      reverse_proxy 127.0.0.1:${toString cfg.port}
    '';
  };
}
