{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.karinBot;
  hasProject = cfg.project != null;
in
{
  options.ssvgg.karinBot = {
    enable = lib.mkEnableOption "Karin QQ bot";
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/karinjs/karin:browser";
    };
    project = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Seed Karin project containing package.json and pnpm-lock.yaml";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 7777;
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hasProject;
        message = "ssvgg.karinBot.project must be configured";
      }
    ];

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.karin = {
      image = cfg.image;
      ports = [ "127.0.0.1:${toString cfg.webuiPort}:7777" ];
      volumes = [ "/var/lib/karin:/app" ];
      environment = {
        TZ = "Asia/Shanghai";
      };
      extraOptions = [ "--shm-size=1g" ];
    };

    users.groups.karin = { };
    users.users.karin = {
      isSystemUser = true;
      group = "karin";
    };
    systemd.tmpfiles.rules = [ "d /var/lib/karin 0755 karin karin -" ];
    systemd.services.podman-karin = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig.ExecStartPre = pkgs.writeShellScript "seed-karin-project" ''
        install -d -o karin -g karin /var/lib/karin
        install -o karin -g karin ${cfg.project}/package.json /var/lib/karin/package.json
        install -o karin -g karin ${cfg.project}/pnpm-lock.yaml /var/lib/karin/pnpm-lock.yaml
      '';
    };
  };
}
