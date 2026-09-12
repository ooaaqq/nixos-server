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
  packagedNoneBotProject =
    if hasNoneBot then
      pkgs.runCommandLocal "qq-bot-project" { } ''
        mkdir -p "$out"
        cp -r ${cfg.nonebotProject}/. "$out/"
        ${lib.optionalString hasParserLite ''
          mkdir -p "$out/nonebot_plugin_parser_lite"
          cp -r ${cfg.parserLiteSource}/. "$out/nonebot_plugin_parser_lite/"
        ''}
      ''
    else
      null;
in
{
  options.ssvgg.qqBot = {
    enable = lib.mkEnableOption "NoneBot QQ bot connected to LLBot Milky";
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/motricseven7/snowluma:latest";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 5099;
    };
    noVncPort = lib.mkOption {
      type = lib.types.port;
      default = 6081;
    };
    onebotHttpPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
    };
    onebotWsPort = lib.mkOption {
      type = lib.types.port;
      default = 3001;
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
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Additional environment variables for the NoneBot service";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    users.groups.qq-bot = lib.mkIf hasNoneBot { };
    users.users.qq-bot = lib.mkIf hasNoneBot {
      isSystemUser = true;
      group = "qq-bot";
    };

    systemd.tmpfiles.rules = lib.optionals hasNoneBot [
      "d /var/cache/qq-bot 0755 qq-bot qq-bot -"
      "d /var/lib/qq-bot/bilibili 0700 qq-bot qq-bot -"
      "z /var/lib/qq-bot/bilibili/subscription.sqlite3 0600 qq-bot qq-bot -"
      "z /var/lib/qq-bot/bilibili/subscription.sqlite3-* 0600 qq-bot qq-bot -"
      "d /var/lib/qq-bot/config 0700 qq-bot qq-bot -"
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
        LOCALSTORE_CACHE_DIR = "/var/cache/qq-bot/nonebot2";
        LOCALSTORE_CONFIG_DIR = "/var/lib/qq-bot/config";
        LOCALSTORE_DATA_DIR = "/var/lib/qq-bot/data";
        # LLBot accepts the local Milky connection; authentication is supplied by
        # the environment file when the deployment enables it.
        MILKY_CLIENTS = ''[{"host":"127.0.0.1","port":3010,"secure":false}]'';
        PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs}/bin/node";
        PLAYWRIGHT_BROWSERS_PATH = playwrightBrowsers;
        UV_CACHE_DIR = "/var/cache/qq-bot/uv";
        UV_NO_MANAGED_PYTHON = "1";
        UV_PROJECT_ENVIRONMENT = "/var/lib/qq-bot/venv";
        UV_PYTHON = "${pkgs.python314}/bin/python3";
      }
      // cfg.environment;
      path = [
        pkgs.deno
        pkgs.ffmpeg-headless
      ];
      preStart = ''
        parser_cache=/var/cache/qq-bot/nonebot2/nonebot_plugin_parser
        if [ -d "$parser_cache" ]; then
          ${pkgs.findutils}/bin/find "$parser_cache" -type d -exec ${pkgs.coreutils}/bin/chmod 0755 {} +
          ${pkgs.findutils}/bin/find "$parser_cache" -type f -exec ${pkgs.coreutils}/bin/chmod 0644 {} +
        fi
      '';
      serviceConfig = {
        User = "qq-bot";
        Group = "qq-bot";
        StateDirectory = "qq-bot";
        StateDirectoryMode = "0700";
        CacheDirectory = "qq-bot";
        # Parser media is shared read-only with the SnowLuma container.
        UMask = "0022";
        WorkingDirectory = packagedNoneBotProject;
        ExecStart = "${pkgs.uv}/bin/uv run --frozen --no-managed-python python ${packagedNoneBotProject}/bot.py";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
