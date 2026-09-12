{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.qqBot;
  hasNoneBot = cfg.nonebotProject != null;
  hasParserLite = cfg.parserLiteSource != null;
  playwrightBrowsers = pkgs.callPackage ../packages/playwright-browsers-1.62.nix { };
  startNoneBot = pkgs.writeShellScript "qq-bot-start" ''
    set -euo pipefail
    token="''${ONEBOT_ACCESS_TOKEN:-}"
    export MILKY_CLIENTS="$(${pkgs.jq}/bin/jq -cn \
      --arg host ${lib.escapeShellArg cfg.milkyHost} \
      --argjson port ${toString cfg.milkyPort} \
      --arg token "$token" \
      '[{host: $host, port: $port, access_token: $token, secure: false}]')"
    exec ${pkgs.uv}/bin/uv run --frozen --no-managed-python python ${packagedNoneBotProject}/bot.py
  '';
  packagedNoneBotProject =
    if hasNoneBot then
      pkgs.runCommandLocal "qq-bot-project" { } ''
        mkdir -p "$out"
        cp -r ${cfg.nonebotProject}/. "$out/"
        ${lib.optionalString hasParserLite ''
          mkdir -p "$out/nonebot_plugin_parser_lite"
          cp -r ${cfg.parserLiteSource}/src/nonebot_plugin_parser_lite/. "$out/nonebot_plugin_parser_lite/"
        ''}
      ''
    else
      null;
in
{
  options.ssvgg.qqBot = {
    enable = lib.mkEnableOption "NoneBot QQ bot connected to LLBot Milky";
    milkyHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "LLBot Milky host reachable by NoneBot";
    };
    milkyPort = lib.mkOption {
      type = lib.types.port;
      default = 3010;
      description = "LLBot Milky HTTP and WebSocket port";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Environment file containing the LLBot Milky access token";
    };
    runtimeConfigFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qq-bot/config/nonebot.env";
      description = "Mutable NoneBot runtime configuration managed outside Nix";
    };
    nonebotProject = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "NoneBot project containing pyproject.toml, uv.lock, and bot.py";
    };
    parserLiteSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Source directory for nonebot-plugin-parser-lite";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.qq-bot = lib.mkIf hasNoneBot { };
    users.users.qq-bot = lib.mkIf hasNoneBot {
      isSystemUser = true;
      group = "qq-bot";
    };

    systemd.tmpfiles.rules = lib.optionals hasNoneBot [
      "d /var/cache/qq-bot 0755 qq-bot qq-bot -"
      "d /var/cache/qq-bot/nonebot2 0755 qq-bot qq-bot -"
      "d /var/lib/qq-bot/bilibili 0700 qq-bot qq-bot -"
      "z /var/lib/qq-bot/bilibili/subscription.sqlite3 0600 qq-bot qq-bot -"
      "z /var/lib/qq-bot/bilibili/subscription.sqlite3-* 0600 qq-bot qq-bot -"
      "d /var/lib/qq-bot/config 0700 qq-bot qq-bot -"
      "f ${cfg.runtimeConfigFile} 0640 qq-bot qq-bot -"
      "d /var/lib/qq-bot/data 0700 qq-bot qq-bot -"
      "d /var/lib/qq-bot/meme-generator 0755 qq-bot qq-bot -"
      "d /var/lib/qq-bot/config/nonebot_plugin_parser 0700 qq-bot qq-bot -"
      "z /var/lib/qq-bot/config/nonebot_plugin_parser/bilibili_cookies.json 0600 qq-bot qq-bot -"
    ];

    systemd.services.qq-bot = lib.mkIf hasNoneBot {
      description = "NoneBot QQ bot";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "podman-llbot.service"
      ];
      after = [
        "network-online.target"
        "podman-llbot.service"
      ];
      environment = {
        DRIVER = "~httpx+~websockets";
        FONTCONFIG_FILE = playwrightBrowsers.fontconfigFile;
        LD_LIBRARY_PATH = lib.makeLibraryPath [
          pkgs.expat
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
        ];
        HOME = "/var/lib/qq-bot";
        XDG_CONFIG_HOME = "/var/lib/qq-bot/config";
        XDG_CACHE_HOME = "/var/cache/qq-bot";
        XDG_DATA_HOME = "/var/lib/qq-bot/data";
        LOCALSTORE_CACHE_DIR = "/var/cache/qq-bot/nonebot2";
        LOCALSTORE_CONFIG_DIR = "/var/lib/qq-bot/config";
        LOCALSTORE_DATA_DIR = "/var/lib/qq-bot/data";
        PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs}/bin/node";
        PLAYWRIGHT_BROWSERS_PATH = playwrightBrowsers;
        UV_CACHE_DIR = "/var/cache/qq-bot/uv";
        UV_NO_MANAGED_PYTHON = "1";
        UV_PROJECT_ENVIRONMENT = "/var/lib/qq-bot/venv";
        UV_PYTHON = "${pkgs.python314}/bin/python3";
      };
      path = [
        pkgs.deno
        pkgs.ffmpeg-headless
      ];
      preStart = ''
        runtime_config=${lib.escapeShellArg cfg.runtimeConfigFile}
        example_config=${lib.escapeShellArg "${cfg.nonebotProject}/nonebot.env.example"}
        if [ ! -s "$runtime_config" ] && [ -f "$example_config" ]; then
          ${pkgs.coreutils}/bin/install -o qq-bot -g qq-bot -m 0640 "$example_config" "$runtime_config"
        fi
        parser_cache=/var/cache/qq-bot/nonebot2/nonebot_plugin_parser
        if [ -d "$parser_cache" ]; then
          ${pkgs.findutils}/bin/find "$parser_cache" -type d -exec ${pkgs.coreutils}/bin/chmod 0755 {} +
          ${pkgs.findutils}/bin/find "$parser_cache" -type f -exec ${pkgs.coreutils}/bin/chmod 0644 {} +
        fi
      '';
      serviceConfig = {
        User = "qq-bot";
        Group = "qq-bot";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile ++ [
          cfg.runtimeConfigFile
        ];
        StateDirectory = "qq-bot";
        StateDirectoryMode = "0700";
        CacheDirectory = "qq-bot";
        UMask = "0022";
        WorkingDirectory = packagedNoneBotProject;
        ExecStart = startNoneBot;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
