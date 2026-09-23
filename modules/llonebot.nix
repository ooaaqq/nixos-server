{
  config,
  lib,
  ...
}:
let
  cfg = config.ssvgg.llonebot;
  pmhqEnvironmentFiles = lib.optional (cfg.pmhqEnvironmentFile != null) cfg.pmhqEnvironmentFile;
in
{
  options.ssvgg.llonebot = {
    enable = lib.mkEnableOption "LLOneBot with PMHQ";
    llbotImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/linyuchen/llbot:8.2.1";
    };
    pmhqImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/linyuchen/pmhq:8.1.1";
    };
    qqNumber = lib.mkOption {
      type = lib.types.str;
      default = "1349874678";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/llonebot";
    };
    pmhqEnvironmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Environment file containing PMHQ credentials, passed only to PMHQ and LLBot.";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 3080;
      description = "Loopback WebUI port used for the SSH tunnel and health checks.";
    };
    pmhqPort = lib.mkOption {
      type = lib.types.port;
      default = 13000;
    };
    sharedMediaDirectory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Host media directory mounted read-only at the same path in LLBot.";
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
      environmentFiles = pmhqEnvironmentFiles;
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
      environmentFiles = pmhqEnvironmentFiles;
      cmd = [ "--qq=${cfg.qqNumber}" ];
      volumes = [
        "${cfg.dataDirectory}/llbot:/app/llbot/data"
      ]
      ++ lib.optional (
        cfg.sharedMediaDirectory != null
      ) "${cfg.sharedMediaDirectory}:${cfg.sharedMediaDirectory}:ro";
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
    systemd.services.podman-pmhq = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
    systemd.services.podman-llbot = {
      wants = [ "podman-pmhq.service" ];
      after = [ "podman-pmhq.service" ];
    };
  };
}
