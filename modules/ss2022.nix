{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.ss2022;
  inherit (cfg) method port;
  secret = config.sops.secrets."ss2022/environment";
  serverConfig = pkgs.writeText "ss2022-server.json" (
    builtins.toJSON {
      # A wildcard IPv6 socket is dual-stack on Linux when bindv6only is 0.
      server = "::";
      server_port = port;
      inherit method;
      password = "\${SS2022_PASSWORD}";
      mode = "tcp_and_udp";
      no_delay = true;
      fast_open = true;
      udp_timeout = 300;
      udp_max_associations = 512;
      nofile = 65536;
    }
  );
in
{
  options.ssvgg.ss2022 = {
    enable = lib.mkEnableOption "a Shadowsocks 2022 server";
    credentialFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing an SS2022_PASSWORD environment variable.";
    };
    method = lib.mkOption {
      type = lib.types.enum [
        "2022-blake3-aes-128-gcm"
        "2022-blake3-aes-256-gcm"
      ];
      default = "2022-blake3-aes-128-gcm";
      description = "Shadowsocks 2022 encryption method.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8388;
      description = "TCP and UDP listen port.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl = {
      "net.ipv4.tcp_fastopen" = 3;
      "net.ipv6.bindv6only" = 0;
    };

    networking.firewall = {
      allowedTCPPorts = [ port ];
      allowedUDPPorts = [ port ];
    };

    sops.secrets."ss2022/environment" = {
      sopsFile = cfg.credentialFile;
      key = "data";
      restartUnits = [ "ss2022.service" ];
    };

    systemd.services.ss2022 = {
      description = "Shadowsocks 2022 server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment.RUST_LOG = "warn";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.shadowsocks-rust}/bin/ssserver -c ${serverConfig}";
        EnvironmentFile = secret.path;
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        Restart = "on-failure";
        RestartSec = "2s";
        LimitNOFILE = 65536;
        UMask = "0077";
      };
    };
  };
}
