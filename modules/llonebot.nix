{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.llonebot;
  environmentFiles = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
  llbotConfigPath = "${cfg.dataDirectory}/llbot/config_${cfg.qqNumber}.json";
  prepareLlbotConfig = pkgs.writeShellScript "llonebot-prepare-llbot-config" ''
    set -euo pipefail

    config_path=${lib.escapeShellArg llbotConfigPath}
    ${pkgs.coreutils}/bin/install -d -m 0700 -o llonebot -g llonebot "$(dirname "$config_path")"
    token="$(${pkgs.coreutils}/bin/printenv ${lib.escapeShellArg cfg.milkyTokenEnvironmentVariable} || true)"
    temporary_path="$(${pkgs.coreutils}/bin/mktemp "$(dirname "$config_path")/.config.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary_path"' EXIT

    if [ -e "$config_path" ]; then
      existing_config="$(${pkgs.coreutils}/bin/cat "$config_path")"
    else
      existing_config='{}'
    fi

    printf '%s\n' "$existing_config" | ${pkgs.jq}/bin/jq \
      --arg token "$token" \
      --argjson webuiPort ${toString cfg.webuiPort} \
      --argjson milkyPort ${toString cfg.milkyPort} \
      ' .webui = (.webui // {})
        | .webui.enable = true
        | .webui.host = "0.0.0.0"
        | .webui.port = $webuiPort
        | .milky = (.milky // {})
        | .milky.enable = true
        | .milky.reportSelfMessage = false
        | .milky.http = (.milky.http // {})
        | .milky.http.host = "127.0.0.1"
        | .milky.http.port = $milkyPort
        | .milky.http.prefix = ""
        | .milky.http.accessToken = $token
        | .milky.webhook = (.milky.webhook // {urls: [], accessToken: ""})' > "$temporary_path"

    ${pkgs.coreutils}/bin/chown llonebot:llonebot "$temporary_path"
    ${pkgs.coreutils}/bin/chmod 0600 "$temporary_path"
    ${pkgs.coreutils}/bin/mv "$temporary_path" "$config_path"
  '';
in
{
  options.ssvgg.llonebot = {
    enable = lib.mkEnableOption "LLOneBot with PMHQ and Milky";
    llbotImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/linyuchen/llbot:latest";
    };
    pmhqImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/linyuchen/pmhq:latest";
    };
    qqNumber = lib.mkOption {
      type = lib.types.str;
      default = "1349874678";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/llonebot";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };
    milkyTokenEnvironmentVariable = lib.mkOption {
      type = lib.types.str;
      default = "ONEBOT_ACCESS_TOKEN";
      description = "Environment variable containing the Milky access token.";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 3080;
    };
    milkyPort = lib.mkOption {
      type = lib.types.port;
      default = 3010;
    };
    pmhqPort = lib.mkOption {
      type = lib.types.port;
      default = 13000;
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers.pmhq = {
      image = cfg.pmhqImage;
      environment = {
        AUTO_LOGIN_QQ = cfg.qqNumber;
        TZ = "Asia/Shanghai";
      };
      environmentFiles = environmentFiles;
      volumes = [ "${cfg.dataDirectory}/pmhq:/app/data" ];
      extraOptions = [
        "--network=host"
        "--shm-size=1g"
      ];
    };

    virtualisation.oci-containers.containers.llbot = {
      image = cfg.llbotImage;
      environment = {
        PROTOCOL_MODE = "pmhq";
        PMHQ_HOST = "127.0.0.1";
        PMHQ_PORT = toString cfg.pmhqPort;
        WEBUI_PORT = toString cfg.webuiPort;
        TZ = "Asia/Shanghai";
      };
      environmentFiles = environmentFiles;
      volumes = [ "${cfg.dataDirectory}/llbot:/app/llbot/data" ];
      extraOptions = [
        "--network=host"
        "--shm-size=1g"
      ];
    };

    users.groups.llonebot = { };
    users.users.llonebot = {
      isSystemUser = true;
      group = "llonebot";
    };
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDirectory} 0750 llonebot llonebot -"
      "d ${cfg.dataDirectory}/pmhq 0700 llonebot llonebot -"
      "d ${cfg.dataDirectory}/llbot 0700 llonebot llonebot -"
    ];
    systemd.services.llonebot-config = {
      description = "Prepare the LLOneBot Milky configuration";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-llbot.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        EnvironmentFile = environmentFiles;
        ExecStart = prepareLlbotConfig;
      };
    };
    systemd.services.podman-pmhq = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
    systemd.services.podman-llbot = {
      requires = [ "llonebot-config.service" ];
      wants = [ "podman-pmhq.service" ];
      after = [
        "llonebot-config.service"
        "podman-pmhq.service"
      ];
    };
  };
}
