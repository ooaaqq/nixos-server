{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.qqBot;
  hasMain = cfg.mainProject != null;
  playwrightBrowsers = pkgs.callPackage ../packages/playwright-browsers-1.63.nix { };
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
    pkgs.git
  ];

  mainEnvironment = commonEnvironment // {
    DRIVER = "~fastapi+~httpx+~websockets";
    HOME = "/var/lib/qq-bot/main";
    LOCALSTORE_CACHE_DIR = "/var/cache/qq-bot/main";
    LOCALSTORE_CONFIG_DIR = "/var/lib/qq-bot/main/config";
    LOCALSTORE_DATA_DIR = "/var/lib/qq-bot/main/data";
    UV_PROJECT_ENVIRONMENT = "/var/lib/qq-bot/main/venv";
  };

  runtimeConfigSetup = runtimeConfig: exampleConfig: extra: ''
    ${pkgs.coreutils}/bin/install -d -o qq-bot -g qq-bot -m 0700 "$(dirname ${lib.escapeShellArg runtimeConfig})"
    ${lib.optionalString (exampleConfig != null) ''
      if [ ! -s ${lib.escapeShellArg runtimeConfig} ] && [ -f ${lib.escapeShellArg exampleConfig} ]; then
        ${pkgs.coreutils}/bin/install -o qq-bot -g qq-bot -m 0640 \
          ${lib.escapeShellArg exampleConfig} ${lib.escapeShellArg runtimeConfig}
      fi
    ''}
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
    mainPort = lib.mkOption {
      type = lib.types.port;
      default = 3011;
      description = "Main NoneBot HTTP port.";
    };
    milkyTokenEnvironmentVariable = lib.mkOption {
      type = lib.types.str;
      default = "ONEBOT_ACCESS_TOKEN";
      description = "Environment variable containing the Milky access token.";
    };
    mainRuntimeConfigFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qq-bot/main/config/nonebot.env";
      description = "Mutable live configuration for the Milky instance; deployments do not overwrite it.";
    };
    mainRuntimeConfigSeedFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "One-time seed copied to mainRuntimeConfigFile only when the live file is absent.";
    };
    mainProject = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "NoneBot project for Milky plugins.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = hasMain;
        message = "ssvgg.qqBot requires mainProject";
      }
    ];

    users.groups.qq-bot = lib.mkIf hasMain { };
    users.users.qq-bot = lib.mkIf hasMain {
      isSystemUser = true;
      group = "qq-bot";
    };

    systemd.tmpfiles.rules = lib.optionals hasMain [
      "d /var/cache/qq-bot 0755 qq-bot qq-bot -"
      "d /var/cache/qq-bot/uv 0750 qq-bot qq-bot -"
      "d /var/cache/qq-bot/main 0750 qq-bot qq-bot -"
      "d /var/lib/qq-bot/main 0700 qq-bot qq-bot -"
      "d /var/lib/qq-bot/main/config 0700 qq-bot qq-bot -"
      "f ${cfg.mainRuntimeConfigFile} 0640 qq-bot qq-bot -"
      "d /var/lib/qq-bot/main/data 0700 qq-bot qq-bot -"
    ];

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
      preStart = runtimeConfigSetup cfg.mainRuntimeConfigFile cfg.mainRuntimeConfigSeedFile ''
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
        EnvironmentFile = [ cfg.mainRuntimeConfigFile ];
        WorkingDirectory = mainProject;
        ExecStart = startMain;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
