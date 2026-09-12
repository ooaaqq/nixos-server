{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ssvgg.karinBot;
  environmentFiles = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
  milkyConfigPath = "${cfg.dataDirectory}/@karinjs/@karinjs/plugin-adapter-milky/config/config.json";
  prepareKarinMilkyConfig = pkgs.writeShellScript "karin-prepare-milky-config" ''
    set -euo pipefail

    config_path=${lib.escapeShellArg milkyConfigPath}
    ${pkgs.coreutils}/bin/install -d -m 0750 -o karin -g karin "$(dirname "$config_path")"
    # Runtime settings belong to the application after first initialization.
    if [ -e "$config_path" ]; then exit 0; fi
    token="$(${pkgs.coreutils}/bin/printenv ${lib.escapeShellArg cfg.milkyTokenEnvironmentVariable} || true)"
    temporary_path="$(${pkgs.coreutils}/bin/mktemp "$(dirname "$config_path")/.config.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary_path"' EXIT

    if [ -e "$config_path" ]; then
      existing_config="$(${pkgs.coreutils}/bin/cat "$config_path")"
    else
      existing_config='{}'
    fi

    printf '%s\n' "$existing_config" | ${pkgs.jq}/bin/jq \
      --arg url ${lib.escapeShellArg cfg.milkyUrl} \
      --arg token "$token" \
      ' .reconnectMaxCount = (.reconnectMaxCount // -1)
        | .reconnectInterval = (.reconnectInterval // 5)
        | .webhookToken = (.webhookToken // "")
        | .bots = ((.bots // [])
          | map(select(.protocol != "websocket" or .url != $url))
          + [{protocol: "websocket", url: $url, token: $token}])' > "$temporary_path"

    ${pkgs.coreutils}/bin/chown karin:karin "$temporary_path"
    ${pkgs.coreutils}/bin/chmod 0640 "$temporary_path"
    ${pkgs.coreutils}/bin/mv "$temporary_path" "$config_path"
  '';
in
{
  options.ssvgg.karinBot = {
    enable = lib.mkEnableOption "Karin Milky bot";
    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/karinjs/karin:browser";
    };
    project = lib.mkOption {
      type = lib.types.path;
      description = "First-install seed only; existing application dependencies are managed by Karin";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Environment file containing the Milky access token.";
    };
    milkyUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:3010";
    };
    milkyTokenEnvironmentVariable = lib.mkOption {
      type = lib.types.str;
      default = "ONEBOT_ACCESS_TOKEN";
      description = "Environment variable containing the Milky access token.";
    };
    dataDirectory = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/karin";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 7777;
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "karin-manage";
        runtimeInputs = with pkgs; [
          coreutils
          gnutar
          gzip
          podman
          systemd
          util-linux
        ];
        runtimeEnv = {
          KARIN_DATA = toString cfg.dataDirectory;
          KARIN_BACKUPS = "/var/backups/karin";
        };
        text = builtins.readFile ../scripts/karin-manage.sh;
      })
    ];
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";
    virtualisation.oci-containers.containers.karin = {
      image = cfg.image;
      ports = [ "127.0.0.1:${toString cfg.webuiPort}:7777" ];
      volumes = [ "${cfg.dataDirectory}:/app" ];
      environment = {
        TZ = "Asia/Shanghai";
      };
      extraOptions = [
        "--network=host"
        "--shm-size=1g"
      ];
    };
    users.groups.karin = { };
    users.users.karin = {
      isSystemUser = true;
      group = "karin";
    };
    systemd.tmpfiles.rules = [ "d ${cfg.dataDirectory} 0750 karin karin -" ];
    systemd.services.karin-config = {
      description = "Prepare the Karin Milky adapter configuration";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-karin.service" ];
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = environmentFiles;
        ExecStart = prepareKarinMilkyConfig;
      };
    };
    systemd.services.podman-karin = {
      requires = [ "karin-config.service" ];
      wants = [
        "network-online.target"
        "podman-llbot.service"
      ];
      after = [
        "network-online.target"
        "karin-config.service"
        "podman-llbot.service"
      ];
      serviceConfig.ExecStartPre = pkgs.writeShellScript "seed-karin-project" ''
        data_dir=${lib.escapeShellArg cfg.dataDirectory}
        install -d -o karin -g karin "$data_dir"
        # Seed once. WebUI/package-manager changes survive service restarts.
        if [ ! -e "$data_dir/package.json" ]; then
          install -m 0644 -o karin -g karin ${cfg.project}/package.json "$data_dir/package.json"
          install -m 0644 -o karin -g karin ${cfg.project}/pnpm-lock.yaml "$data_dir/pnpm-lock.yaml"
        fi
      '';
    };
  };
}
