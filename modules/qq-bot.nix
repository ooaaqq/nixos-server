{ config, lib, ... }:
let
  cfg = config.ssvgg.qqBot;
in
{
  options.ssvgg.qqBot = {
    enable = lib.mkEnableOption "LLBot QQ bot";
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/linyuchen/llbot:8.1.10";
    };
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/llbot";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 3080;
    };
    milkyPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
    };
  };
  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.llbot = {
      image = cfg.image;
      ports = [
        "127.0.0.1:${toString cfg.webuiPort}:3080"
        "127.0.0.1:${toString cfg.milkyPort}:3000"
      ];
      volumes = [ "${cfg.dataDir}:/app/llbot/data:rw" ];
      extraOptions = [ "--pull=missing" ];
    };
    systemd.tmpfiles.rules = [ "d ${cfg.dataDir} 0750 root root -" ];
  };
}
