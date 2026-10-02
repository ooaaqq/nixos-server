{ config, lib, ... }:

let
  cfg = config.ssvgg.eopMilky;
  biliSecret = config.sops.secrets."eop-milky/bilibili-cookies";
  weiboSecret = config.sops.secrets."eop-milky/weibo-cookie";
in
{
  options.ssvgg.eopMilky = {
    enable = lib.mkEnableOption "EoP notifications through the local Milky API";
    image = lib.mkOption {
      type = lib.types.str;
      description = "Pinned EoP-Milky OCI image.";
    };
    configFile = lib.mkOption {
      type = lib.types.path;
      description = "Mutable EoP JavaScript configuration.";
    };
    bilibiliCredentialFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing the biliup JSON cookie document for the monitoring account.";
    };
    weiboCredentialFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing the Weibo Cookie header.";
    };
    recipient = lib.mkOption {
      type = lib.types.ints.positive;
      description = "QQ user ID passed to the Milky sender.";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/eop-milky";
    };
    milkyBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:3010";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.image != "";
        message = "ssvgg.eopMilky.image must be pinned";
      }
    ];
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    sops.secrets."eop-milky/bilibili-cookies" = {
      sopsFile = cfg.bilibiliCredentialFile;
      key = "data";
      restartUnits = [ "podman-eop-milky.service" ];
    };
    sops.secrets."eop-milky/weibo-cookie" = {
      sopsFile = cfg.weiboCredentialFile;
      key = "data";
      restartUnits = [ "podman-eop-milky.service" ];
    };

    virtualisation.oci-containers.containers.eop-milky = {
      image = cfg.image;
      environment = {
        EOP_QQ_RECIPIENT = toString cfg.recipient;
        EOP_MILKY_BASE_URL = cfg.milkyBaseUrl;
        EOP_MILKY_MODE = "send";
        COOKIES_BILIBILI_FILE = "/run/eop-milky/bilibili-cookies.json";
      };
      environmentFiles = [ weiboSecret.path ];
      volumes = [
        "${cfg.configFile}:/app/config.eop.js:ro"
        "${cfg.dataDirectory}/db:/app/db"
        "${biliSecret.path}:/run/eop-milky/bilibili-cookies.json:ro"
      ];
      extraOptions = [ "--network=host" ];
      cmd = [
        "run"
        "-c"
        "/app/config.eop.js"
        "--send"
      ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDirectory} 0700 root root -"
      "d ${cfg.dataDirectory}/db 0700 root root -"
    ];
    systemd.services.podman-eop-milky = {
      wants = [
        "network-online.target"
        "podman-llbot.service"
      ];
      after = [
        "network-online.target"
        "podman-llbot.service"
      ];
    };
  };
}
