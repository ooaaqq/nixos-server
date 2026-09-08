{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.riftWeb;
  usersSecret = config.sops.secrets."rift-web/users";
  kaggleSecret = config.sops.secrets."rift-web/kaggle";
  validateUsers = pkgs.writeShellApplication {
    name = "rift-web-validate-users";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      jq --exit-status '
        type == "array" and length > 0 and
        all(.[];
          (.username | type == "string" and length > 0 and length <= 32) and
          (.token_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.admin | type == "boolean")
        )
      ' "$1" >/dev/null
    '';
  };
  prepareKaggle = pkgs.writeShellApplication {
    name = "rift-web-prepare-kaggle";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      source_file="$1"
      destination=/var/lib/rift-web/kaggle/credentials.json
      jq --exit-status '
        (.username | type == "string" and length > 0) and
        (.access_token | type == "string" and length > 0) and
        (.refresh_token | type == "string" and length > 0)
      ' "$source_file" >/dev/null
      install -d -m 0700 /var/lib/rift-web/kaggle
      install -m 0600 "$source_file" "$destination"
    '';
  };
  commonEnvironment = [
    "RIFT_WEB_STATE_DIRECTORY=/var/lib/rift-web"
    "RIFT_WEB_USERS_FILE=%d/users.json"
    "RIFT_WEB_LISTEN_HOST=127.0.0.1"
    "RIFT_WEB_LISTEN_PORT=${toString cfg.port}"
    "RIFT_WEB_MAX_UPLOAD_BYTES=${toString cfg.maxUploadBytes}"
    "RIFT_WEB_RETENTION_DAYS=${toString cfg.retentionDays}"
    "TZ=Asia/Shanghai"
  ];
  commonHardening = {
    User = "rift-web";
    Group = "rift-web";
    WorkingDirectory = "/var/lib/rift-web";
    StateDirectory = "rift-web";
    StateDirectoryMode = "0700";
    UMask = "0077";
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectKernelLogs = true;
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
in
{
  options.ssvgg.riftWeb = {
    enable = lib.mkEnableOption "the private RIFT-SVC web queue";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Pinned RIFT-SVC web package.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "svc.example.com";
      description = "Public hostname for the authenticated queue.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8766;
      description = "Loopback port used by the ASGI server.";
    };
    maxUploadBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 500 * 1024 * 1024;
      description = "Maximum size of one uploaded audio file.";
    };
    retentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 14;
      description = "Days to retain private audio after task completion.";
    };
    credentialsFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing users and Kaggle JSON credentials.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "ssvgg.riftWeb.package must be set when the service is enabled";
      }
      {
        assertion = config.ssvgg.web.enable;
        message = "ssvgg.riftWeb requires ssvgg.web.enable";
      }
    ];

    users.groups.rift-web = { };
    users.users.rift-web = {
      isSystemUser = true;
      group = "rift-web";
      home = "/var/lib/rift-web";
    };

    sops.secrets."rift-web/users" = {
      sopsFile = cfg.credentialsFile;
      key = "users";
      restartUnits = [ "rift-web.service" ];
    };
    sops.secrets."rift-web/kaggle" = {
      sopsFile = cfg.credentialsFile;
      key = "kaggle";
      restartUnits = [ "rift-dispatcher.service" ];
    };

    systemd.services.rift-web = {
      description = "RIFT-SVC private web queue";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = commonHardening // {
        Type = "exec";
        LoadCredential = "users.json:${usersSecret.path}";
        Environment = commonEnvironment;
        ExecStartPre = "${validateUsers}/bin/rift-web-validate-users %d/users.json";
        ExecStart = "${cfg.package}/bin/rift-web";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
        MemoryMax = "512M";
        TasksMax = 256;
      };
    };

    systemd.services.rift-dispatcher = {
      description = "RIFT-SVC serial Kaggle dispatcher";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "rift-web.service"
      ];
      serviceConfig = commonHardening // {
        Type = "exec";
        LoadCredential = [
          "users.json:${usersSecret.path}"
          "kaggle.json:${kaggleSecret.path}"
        ];
        Environment = commonEnvironment ++ [
          "KAGGLE_CONFIG_DIR=/var/lib/rift-web/kaggle"
        ];
        ExecStartPre = "${prepareKaggle}/bin/rift-web-prepare-kaggle %d/kaggle.json";
        ExecStart = "${cfg.package}/bin/rift-dispatcher";
        Restart = "on-failure";
        RestartSec = "15s";
        TimeoutStopSec = "6h";
        MemoryMax = "1G";
        TasksMax = 512;
      };
    };

    systemd.services.rift-cleanup = {
      description = "Remove expired RIFT queue audio";
      serviceConfig = commonHardening // {
        Type = "oneshot";
        LoadCredential = "users.json:${usersSecret.path}";
        Environment = commonEnvironment;
        ExecStart = "${cfg.package}/bin/rift-cleanup";
        MemoryMax = "256M";
        TasksMax = 64;
      };
    };

    systemd.timers.rift-cleanup = {
      description = "Daily RIFT queue audio retention cleanup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30m";
        Unit = "rift-cleanup.service";
      };
    };

    services.caddy.virtualHosts.${cfg.domain}.extraConfig = ''
      request_body {
        max_size 500MB
      }
      header {
        Content-Security-Policy "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; object-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'"
        Referrer-Policy "no-referrer"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
      }
      reverse_proxy 127.0.0.1:${toString cfg.port}
    '';
  };
}
