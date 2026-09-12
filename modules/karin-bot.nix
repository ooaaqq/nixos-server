{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.karinBot;
in
{
  options.ssvgg.karinBot = {
    enable = lib.mkEnableOption "Karin Milky bot";
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/karinjs/karin:browser";
    };
    project = lib.mkOption {
      type = lib.types.path;
      description = "Seed Karin project containing package.json and pnpm-lock.yaml";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/karin";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 7777;
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.karin = {
      image = cfg.image;
      ports = [ "127.0.0.1:${toString cfg.webuiPort}:7777" ];
      volumes = [ "${cfg.dataDirectory}:/app" ];
      environment = {
        TZ = "Asia/Shanghai";
      };
      extraOptions = [
        "--network=host"
        "--shm-size=1g"
      ];
    };
    users.groups.karin = { };
    users.users.karin = {
      isSystemUser = true;
      group = "karin";
    };
    systemd.tmpfiles.rules = [ "d ${cfg.dataDirectory} 0750 karin karin -" ];
    systemd.services.podman-karin = {
      wants = [
        "network-online.target"
        "podman-llbot.service"
      ];
      after = [
        "network-online.target"
        "podman-llbot.service"
      ];
      serviceConfig.ExecStartPre = pkgs.writeShellScript "seed-karin-project" ''
        install -d -o karin -g karin ${cfg.dataDirectory}
        install -o karin -g karin ${cfg.project}/package.json ${cfg.dataDirectory}/package.json
        install -o karin -g karin ${cfg.project}/pnpm-lock.yaml ${cfg.dataDirectory}/pnpm-lock.yaml
      '';
    };
  };
}
