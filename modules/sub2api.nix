{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.sub2api;
  version = "0.2.4";
  archive = pkgs.fetchurl {
    url = "https://github.com/Wei-Shaw/sub2api/releases/download/v${version}/sub2api_${version}_linux_amd64.tar.gz";
    hash = "sha256-NcrimPq8L7wCan5YXVJmOjeJwTWNU2+10cuayYjASKI=";
  };
  package = pkgs.runCommand "sub2api-${version}" { nativeBuildInputs = [ pkgs.gnutar ]; } ''
    mkdir -p "$out/bin"
    tar -xzf ${archive} -C "$out/bin" sub2api
    chmod 0755 "$out/bin/sub2api"
  '';
  prepareEnvironment = pkgs.writeShellApplication {
    name = "sub2api-prepare-environment";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      environment=/var/lib/sub2api/environment
      if [ ! -e "$environment" ]; then
        umask 0077
        jwt_secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d '[:space:]')"
        totp_key="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d '[:space:]')"
        printf 'JWT_SECRET=%s\nTOTP_ENCRYPTION_KEY=%s\n' \
          "$jwt_secret" "$totp_key" > "$environment"
      fi
    '';
  };
in
{
  options.ssvgg.sub2api = {
    enable = lib.mkEnableOption "the Sub2API gateway";
    domain = lib.mkOption {
      type = lib.types.str;
      default = "api.example.com";
      description = "Public hostname used by Sub2API and its Caddy virtual host.";
    };
    reverseProxy.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Expose Sub2API through the module's Caddy virtual host.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.reverseProxy.enable || config.ssvgg.web.enable;
        message = "ssvgg.sub2api reverseProxy requires ssvgg.web.enable";
      }
    ];

    users.groups.sub2api = { };
    users.users.sub2api = {
      isSystemUser = true;
      group = "sub2api";
    };

    services.postgresql = {
      enable = true;
      ensureDatabases = [ "sub2api" ];
      ensureUsers = [
        {
          name = "sub2api";
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers.sub2api = {
      enable = true;
      bind = "127.0.0.1";
      port = 6379;
    };

    systemd.services.sub2api = {
      description = "Sub2API AI API gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "postgresql.service"
        "redis-sub2api.service"
      ];
      requires = [
        "postgresql.service"
        "redis-sub2api.service"
      ];
      serviceConfig = {
        Type = "exec";
        User = "sub2api";
        Group = "sub2api";
        WorkingDirectory = "/var/lib/sub2api";
        Environment = [
          "AUTO_SETUP=true"
          "SERVER_HOST=127.0.0.1"
          "SERVER_PORT=8080"
          "SERVER_MODE=release"
          "SERVER_FRONTEND_URL=https://${cfg.domain}"
          "RUN_MODE=simple"
          "GATEWAY_OPENAI_WS_MODE_ROUTER_V2_ENABLED=true"
          "GATEWAY_OPENAI_WS_PREWARM_GENERATE_ENABLED=true"
          "DATA_DIR=/var/lib/sub2api"
          "DATABASE_HOST=/run/postgresql"
          "DATABASE_PORT=5432"
          "DATABASE_USER=sub2api"
          "DATABASE_PASSWORD="
          "DATABASE_DBNAME=sub2api"
          "DATABASE_SSLMODE=disable"
          "REDIS_HOST=127.0.0.1"
          "REDIS_PORT=6379"
          "REDIS_DB=0"
          "TZ=Asia/Shanghai"
          "SECURITY_URL_ALLOWLIST_ENABLED=true"
          "SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP=false"
          "SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS=false"
          "SECURITY_URL_ALLOWLIST_UPSTREAM_HOSTS=api.openai.com,auth.openai.com"
        ];
        ExecStartPre = "${prepareEnvironment}/bin/sub2api-prepare-environment";
        ExecStart = pkgs.writeShellScript "sub2api-start" ''
          set -a
          . /var/lib/sub2api/environment
          set +a
          exec ${package}/bin/sub2api
        '';
        StateDirectory = "sub2api";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "5s";
        MemoryMax = "2G";
        CapabilityBoundingSet = "";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };

    services.caddy.virtualHosts.${cfg.domain}.extraConfig = lib.mkIf cfg.reverseProxy.enable ''
      reverse_proxy 127.0.0.1:8080
    '';
  };
}
