{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.qqBot;
  hasMain = cfg.mainProject != null;
  hasBilibili = cfg.bilibiliProject != null;
  hasNoneBot = hasMain || hasBilibili;
  playwrightBrowsers = pkgs.callPackage ../packages/playwright-browsers-1.62.nix { };
  packagedProject =
    project:
    if project == null then
      null
    else
      pkgs.runCommandLocal "qq-bot-project" { } ''
        mkdir -p "$out"
        cp -r ${project}/. "$out/"
      '';
  mainProject = packagedProject cfg.mainProject;
  bilibiliProject = packagedProject cfg.bilibiliProject;

  startMain = pkgs.writeShellScript "qq-bot-main-start" ''
    set -euo pipefail
    token="$(${pkgs.coreutils}/bin/printenv ${lib.escapeShellArg cfg.milkyTokenEnvironmentVariable} || true)"
    export MILKY_CLIENTS="$(${pkgs.jq}/bin/jq -cn \
      --arg host ${lib.escapeShellArg cfg.milkyHost} \
      --argjson port ${toString cfg.milkyPort} \
      --arg token "$token" \
      '[{host: $host, port: $port, access_token: $token, secure: false}]')"
    exec ${pkgs.uv}/bin/uv run --frozen --no-managed-python python ${mainProject}/bot.py
  '';

  startBilibili = pkgs.writeShellScript "qq-bot-bilibili-start" ''
    set -euo pipefail
    token="$(${pkgs.coreutils}/bin/printenv ${lib.escapeShellArg cfg.onebotTokenEnvironmentVariable} || true)"
    export ONEBOT_V11_ACCESS_TOKEN="$token"
    export ONEBOT_V11_WS_URLS='["ws://${cfg.onebotWsHost}:${toString cfg.onebotWsPort}"]'
    exec ${pkgs.uv}/bin/uv run --frozen --no-managed-python python ${bilibiliProject}/bot.py
  '';

  commonEnvironment = {
    FONTCONFIG_FILE = playwrightBrowsers.fontconfigFile;
    LD_LIBRARY_PATH = lib.makeLibraryPath [
      pkgs.expat
      pkgs.libglvnd
      pkgs.stdenv.cc.cc.lib
      pkgs.zlib
    ];
    PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs}/bin/node";
    PLAYWRIGHT_BROWSERS_PATH = playwrightBrowsers;
    UV_CACHE_DIR = "/var/cache/qq-bot/uv";
    UV_NO_MANAGED_PYTHON = "1";
    UV_PYTHON = "${pkgs.python314}/bin/python3";
  };

  commonPath = [
    pkgs.deno
    pkgs.ffmpeg-headless
  ];

  mainEnvironment = commonEnvironment // {
    DRIVER = "~fastapi+~httpx+~websockets";
    HOME = "/var/lib/qq-bot/main";
    LOCALSTORE_CACHE_DIR = "/var/cache/qq-bot/main";
    LOCALSTORE_CONFIG_DIR = "/var/lib/qq-bot/main/config";
    LOCALSTORE_DATA_DIR = "/var/lib/qq-bot/main/data";
    UV_PROJECT_ENVIRONMENT = "/var/lib/qq-bot/main/venv";
  };

  bilibiliEnvironment = commonEnvironment // {
    DRIVER = "~fastapi+~httpx+~websockets";
    HOST = "127.0.0.1";
    PORT = toString cfg.bilibiliPort;
    HOME = "/var/lib/qq-bot/bilibili";
    LOCALSTORE_CACHE_DIR = "/var/cache/qq-bot/bilibili";
    LOCALSTORE_CONFIG_DIR = "/var/lib/qq-bot/bilibili/config";
    LOCALSTORE_DATA_DIR = "/var/lib/qq-bot/bilibili/data";
    UV_PROJECT_ENVIRONMENT = "/var/lib/qq-bot/bilibili/venv";
  };

  runtimeConfigSetup = runtimeConfig: exampleConfig: extra: ''
    ${pkgs.coreutils}/bin/install -d -o qq-bot -g qq-bot -m 0700 "$(dirname ${lib.escapeShellArg runtimeConfig})"
    if [ ! -s ${lib.escapeShellArg runtimeConfig} ] && [ -f ${lib.escapeShellArg exampleConfig} ]; then
      ${pkgs.coreutils}/bin/install -o qq-bot -g qq-bot -m 0640 \
        ${lib.escapeShellArg exampleConfig} ${lib.escapeShellArg runtimeConfig}
    fi
    ${extra}
  '';
in
{
  options.ssvgg.qqBot = {
    enable = lib.mkEnableOption "NoneBot QQ bot instances connected to LLBot";
    milkyHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "LLBot Milky host reachable by the main NoneBot instance.";
    };
    milkyPort = lib.mkOption {
      type = lib.types.port;
      default = 3010;
      description = "LLBot Milky HTTP and WebSocket port.";
    };
    onebotWsHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "LLBot OneBot V11 WebSocket host.";
    };
    onebotWsPort = lib.mkOption {
      type = lib.types.port;
      default = 3001;
      description = "LLBot OneBot V11 WebSocket port.";
    };
    mainPort = lib.mkOption {
      type = lib.types.port;
      default = 3011;
      description = "Main NoneBot HTTP port.";
    };
    bilibiliPort = lib.mkOption {
      type = lib.types.port;
      default = 3012;
      description = "Bilibili sidecar HTTP port.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Environment file containing LLBot access tokens.";
    };
    milkyTokenEnvironmentVariable = lib.mkOption {
      type = lib.types.str;
      default = "ONEBOT_ACCESS_TOKEN";
      description = "Environment variable containing the Milky access token.";
    };
    onebotTokenEnvironmentVariable = lib.mkOption {
      type = lib.types.str;
      default = "ONEBOT_ACCESS_TOKEN";
      description = "Environment variable containing the OneBot V11 access token.";
    };
    mainRuntimeConfigFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qq-bot/main/config/nonebot.env";
      description = "Mutable runtime configuration for the Milky instance.";
    };
    bilibiliRuntimeConfigFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qq-bot/bilibili/config/nonebot.env";
      description = "Mutable runtime configuration for the Bilibili sidecar.";
    };
    mainProject = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "NoneBot project for Milky plugins.";
    };
    bilibiliProject = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "NoneBot project for the OneBot V11 Bilibili sidecar.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hasMain || hasBilibili;
        message = "ssvgg.qqBot requires mainProject or bilibiliProject";
      }
    ];

    users.groups.qq-bot = lib.mkIf hasNoneBot { };
    users.users.qq-bot = lib.mkIf hasNoneBot {
      isSystemUser = true;
      group = "qq-bot";
    };

    systemd.tmpfiles.rules = lib.optionals hasNoneBot (
      [
        "d /var/cache/qq-bot 0755 qq-bot qq-bot -"
        "d /var/cache/qq-bot/uv 0750 qq-bot qq-bot -"
      ]
      ++ lib.optionals hasMain [
        "d /var/cache/qq-bot/main 0750 qq-bot qq-bot -"
        "d /var/lib/qq-bot/main 0700 qq-bot qq-bot -"
        "d /var/lib/qq-bot/main/config 0700 qq-bot qq-bot -"
        "f ${cfg.mainRuntimeConfigFile} 0640 qq-bot qq-bot -"
        "d /var/lib/qq-bot/main/data 0700 qq-bot qq-bot -"
      ]
      ++ lib.optionals hasBilibili [
        "d /var/cache/qq-bot/bilibili 0750 qq-bot qq-bot -"
        "d /var/lib/qq-bot/bilibili 0700 qq-bot qq-bot -"
        "d /var/lib/qq-bot/bilibili/config 0700 qq-bot qq-bot -"
        "f ${cfg.bilibiliRuntimeConfigFile} 0640 qq-bot qq-bot -"
        "d /var/lib/qq-bot/bilibili/data 0700 qq-bot qq-bot -"
        "z /var/lib/qq-bot/bilibili/subscription.sqlite3 0600 qq-bot qq-bot -"
        "z /var/lib/qq-bot/bilibili/subscription.sqlite3-* 0600 qq-bot qq-bot -"
      ]
    );

    systemd.services.qq-bot = lib.mkIf hasMain {
      description = "NoneBot QQ bot (Milky)";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "podman-llbot.service"
      ];
      after = [
        "network-online.target"
        "podman-llbot.service"
      ];
      environment = mainEnvironment // {
        PORT = toString cfg.mainPort;
      };
      path = commonPath;
      preStart = runtimeConfigSetup cfg.mainRuntimeConfigFile "${cfg.mainProject}/nonebot.env.example" ''
        parser_cache=/var/cache/qq-bot/main/nonebot_plugin_parser_lite
        if [ -d "$parser_cache" ]; then
          ${pkgs.findutils}/bin/find "$parser_cache" -type d -exec ${pkgs.coreutils}/bin/chmod 0755 {} +
          ${pkgs.findutils}/bin/find "$parser_cache" -type f -exec ${pkgs.coreutils}/bin/chmod 0644 {} +
        fi
        if [ -f ${lib.escapeShellArg "${cfg.mainProject}/migrate.py"} ]; then
          ${pkgs.uv}/bin/uv run --frozen --no-managed-python python ${mainProject}/migrate.py
        fi
      '';
      serviceConfig = {
        User = "qq-bot";
        Group = "qq-bot";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile ++ [
          cfg.mainRuntimeConfigFile
        ];
        WorkingDirectory = mainProject;
        ExecStart = startMain;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.qq-bili = lib.mkIf hasBilibili {
      description = "NoneBot QQ bot (Bilibili OneBot V11 sidecar)";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "podman-llbot.service"
      ];
      after = [
        "network-online.target"
        "podman-llbot.service"
      ];
      environment = bilibiliEnvironment;
      path = commonPath;
      preStart =
        runtimeConfigSetup cfg.bilibiliRuntimeConfigFile "${cfg.bilibiliProject}/nonebot.env.example"
          "";
      serviceConfig = {
        User = "qq-bot";
        Group = "qq-bot";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile ++ [
          cfg.bilibiliRuntimeConfigFile
        ];
        WorkingDirectory = bilibiliProject;
        ExecStart = startBilibili;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
