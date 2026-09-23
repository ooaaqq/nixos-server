{ config, lib, ... }:

let
  cfg = config.ssvgg.astrbot;
in
{
  options.ssvgg.astrbot = {
    enable = lib.mkEnableOption "AstrBot with a loopback-only dashboard and OneBot V11 endpoint";
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/soulter/astrbot@sha256:8e9f108c1470e6dd46bbbaad0d01e93d740dd86ee8d1cd767a10106aefd62ecf";
      description = "Pinned AstrBot container image.";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/astrbot";
      description = "Persistent AstrBot data, configuration, plugins, and database directory.";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 6185;
      description = "Host-loopback port for the AstrBot WebUI.";
    };
    onebotReverseWsPort = lib.mkOption {
      type = lib.types.port;
      default = 6199;
      description = "Host-loopback port for AstrBot's OneBot V11 reverse WebSocket server.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.webuiPort != cfg.onebotReverseWsPort;
        message = "AstrBot WebUI and OneBot reverse WebSocket ports must differ.";
      }
    ];

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    virtualisation.oci-containers.containers.astrbot = {
      image = cfg.image;
      environment.TZ = "Asia/Shanghai";
      ports = [
        "127.0.0.1:${toString cfg.webuiPort}:6185"
        "127.0.0.1:${toString cfg.onebotReverseWsPort}:6199"
      ];
      volumes = [ "${cfg.dataDirectory}:/AstrBot/data" ];
      extraOptions = [ "--shm-size=1g" ];
    };

    systemd.tmpfiles.rules = [ "d ${cfg.dataDirectory} 0700 root root -" ];

    systemd.services.podman-astrbot = {
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
    };
  };
}
