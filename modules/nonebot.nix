{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.nonebot;
  hasMain = cfg.mainProject != null;
  playwrightBrowsers = pkgs.callPackage ../packages/playwright-browsers-1.63.nix { };
  packagedProject =
    project:
    if project == null then
      null
    else
      pkgs.runCommandLocal "nonebot-project" { } ''
        mkdir -p "$out"
        cp -r ${project}/. "$out/"
      '';
  mainProject = packagedProject cfg.mainProject;

  startMain = pkgs.writeShellScript "nonebot-main-start" ''
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
    UV_CACHE_DIR = "/var/cache/nonebot/uv";
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
    HOME = "/var/lib/nonebot/main";
    LOCALSTORE_CACHE_DIR = "/var/cache/nonebot/main";
    LOCALSTORE_CONFIG_DIR = "/var/lib/nonebot/main/config";
    LOCALSTORE_DATA_DIR = "/var/lib/nonebot/main/data";
    UV_PROJECT_ENVIRONMENT = "/var/lib/nonebot/main/venv";
  };

  runtimeConfigSetup = runtimeConfig: exampleConfig: extra: ''
    ${pkgs.coreutils}/bin/install -d -o nonebot -g nonebot -m 0700 "$(dirname ${lib.escapeShellArg runtimeConfig})"
    ${lib.optionalString (exampleConfig != null) ''
      if [ ! -s ${lib.escapeShellArg runtimeConfig} ] && [ -f ${lib.escapeShellArg exampleConfig} ]; then
        ${pkgs.coreutils}/bin/install -o nonebot -g nonebot -m 0640 \
          ${lib.escapeShellArg exampleConfig} ${lib.escapeShellArg runtimeConfig}
      fi
    ''}
    ${extra}
  '';
in
{
  options.ssvgg.nonebot = {
    enable = lib.mkEnableOption "NoneBot main application connected to LLBot";
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
      default = "/var/lib/nonebot/main/config/nonebot.env";
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
        message = "ssvgg.nonebot requires mainProject";
      }
    ];

    users.groups.nonebot = lib.mkIf hasMain { };
    users.users.nonebot = lib.mkIf hasMain {
      isSystemUser = true;
      group = "nonebot";
    };

    systemd.tmpfiles.rules = lib.optionals hasMain [
      "d /var/cache/nonebot 0755 nonebot nonebot -"
      "d /var/cache/nonebot/uv 0750 nonebot nonebot -"
      "d /var/cache/nonebot/main 0750 nonebot nonebot -"
      "d /var/lib/nonebot/main 0700 nonebot nonebot -"
      "d /var/lib/nonebot/main/config 0700 nonebot nonebot -"
      "f ${cfg.mainRuntimeConfigFile} 0640 nonebot nonebot -"
      "d /var/lib/nonebot/main/data 0700 nonebot nonebot -"
    ];

    systemd.services.nonebot = lib.mkIf hasMain {
      description = "NoneBot main application (Milky)";
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
        parser_cache=/var/cache/nonebot/main/nonebot_plugin_parser_lite
        if [ -d "$parser_cache" ]; then
          ${pkgs.findutils}/bin/find "$parser_cache" -type d -exec ${pkgs.coreutils}/bin/chmod 0755 {} +
          ${pkgs.findutils}/bin/find "$parser_cache" -type f -exec ${pkgs.coreutils}/bin/chmod 0644 {} +
        fi
        if [ -f ${lib.escapeShellArg "${cfg.mainProject}/migrate.py"} ]; then
          ${pkgs.uv}/bin/uv run --frozen --no-managed-python python ${mainProject}/migrate.py
        fi
      '';
      serviceConfig = {
        User = "nonebot";
        Group = "nonebot";
        EnvironmentFile = [ cfg.mainRuntimeConfigFile ];
        WorkingDirectory = mainProject;
        ExecStart = startMain;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
