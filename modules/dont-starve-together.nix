{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.dontStarveTogether;
  token = config.sops.secrets."dont-starve-together/cluster_token";
  dataDir = "/var/lib/dst";
  gameDir = "${dataDir}/game";
  curlGnutls =
    (pkgs.curl.override {
      gnutlsSupport = true;
      opensslSupport = false;
      http3Support = false;
    }).overrideAttrs
      (previousAttrs: rec {
        version = "8.22.0";
        src = pkgs.fetchurl {
          url = "https://curl.se/download/curl-${version}.tar.xz";
          hash = "sha256-9+866KIuUh8omAP+k1Q+tkwym1iqc6niJN/ZFaKl9Pc=";
        };
        patches = [
          (builtins.toFile "curl-gnutls-keep-symbols-compatible.patch" ''
            --- a/lib/libcurl.vers.in
            +++ b/lib/libcurl.vers.in
            @@ -1,4 +1,4 @@
            -CURL_@CURL_LIBCURL_VERSIONED_SYMBOLS_PREFIX@@CURL_LIBCURL_VERSIONED_SYMBOLS_SONAME@
            +CURL_@CURL_LIBCURL_VERSIONED_SYMBOLS_PREFIX@3
             {
               global: curl_*;
               local: *;
          '')
        ];
        nativeBuildInputs = (previousAttrs.nativeBuildInputs or [ ]) ++ [ pkgs.patchelf ];
        postFixup = (previousAttrs.postFixup or "") + ''
          patchelf --set-soname libcurl-gnutls.so.4 $out/lib/libcurl.so.4.8.0
        '';
      });
  clusterRoot = "${dataDir}/clusters/${cfg.clusterName}";
  serverExecutable = "${gameDir}/bin64/dontstarve_dedicated_server_nullrenderer_x64";
  updateScript = ''
    ${pkgs.coreutils}/bin/mkdir -p ${gameDir}
    exec ${pkgs.steam-run}/bin/steam-run ${pkgs.steamcmd}/bin/steamcmd \
      +@ShutdownOnFailedCommand 1 \
      +@NoPromptForPassword 1 \
      +force_install_dir ${gameDir} \
      +login anonymous \
      +app_update 343050 validate \
      +quit
  '';
  clusterIni = pkgs.writeText "dst-cluster.ini" ''
    [NETWORK]
    cluster_name = ${cfg.serverName}
    cluster_description = ${cfg.serverDescription}
    cluster_intention = cooperative
    lan_only_cluster = false
    offline_server = false
    tick_rate = 15

    [GAMEPLAY]
    game_mode = survival
    max_players = ${toString cfg.maxPlayers}
    pvp = false
    pause_when_empty = true
    vote_kick_enabled = true
  '';
  masterIni = pkgs.writeText "dst-master.ini" ''
    [NETWORK]
    server_port = 10999

    [SHARD]
    is_master = true
  '';
in
{
  options.ssvgg.dontStarveTogether = {
    enable = lib.mkEnableOption "the Don't Starve Together trial server";
    clusterName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]+";
      default = "my-trial";
      description = "Persistent cluster directory name.";
    };
    serverName = lib.mkOption {
      type = lib.types.str;
      default = "NixOS Server";
      description = "Name written into the DST cluster configuration.";
    };
    serverDescription = lib.mkOption {
      type = lib.types.str;
      default = "Managed declaratively with NixOS.";
      description = "Description shown in the DST server list.";
    };
    maxPlayers = lib.mkOption {
      type = lib.types.ints.between 1 64;
      default = 12;
      description = "Maximum concurrent players.";
    };
    clusterTokenFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing the cluster token for this machine.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."dont-starve-together/cluster_token" = {
      sopsFile = cfg.clusterTokenFile;
      key = "data";
      owner = "dst";
      group = "dst";
      mode = "0400";
      restartUnits = [ "dst-master.service" ];
    };

    users.groups.dst = { };
    users.users.dst = {
      isSystemUser = true;
      group = "dst";
      home = dataDir;
      createHome = true;
    };

    networking.firewall.allowedUDPPorts = [
      10999
      27016
    ];

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0750 dst dst - -"
      "d ${gameDir} 0750 dst dst - -"
      "d ${clusterRoot}/Master 0750 dst dst - -"
    ];

    systemd.services.dst-install-if-missing = {
      description = "Install Don't Starve Together Dedicated Server when absent";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "dst";
        Group = "dst";
        WorkingDirectory = dataDir;
        Environment = [ "HOME=${dataDir}" ];
        TimeoutStartSec = "2h";
        UMask = "0027";
      };
      script = ''
        if [[ -x ${lib.escapeShellArg serverExecutable} ]]; then
          exit 0
        fi
        ${updateScript}
      '';
    };

    # Updates are explicit so a routine boot never waits on SteamCMD or mutates
    # the running server installation. Start this unit during planned maintenance.
    systemd.services.dst-update = {
      description = "Update Don't Starve Together Dedicated Server";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      conflicts = [ "dst-master.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "dst";
        Group = "dst";
        WorkingDirectory = dataDir;
        Environment = [ "HOME=${dataDir}" ];
        TimeoutStartSec = "2h";
        UMask = "0027";
      };
      script = updateScript;
    };

    systemd.services.dst-prepare = {
      description = "Prepare Don't Starve Together trial cluster";
      requiredBy = [ "dst-master.service" ];
      before = [ "dst-master.service" ];
      serviceConfig = {
        Type = "oneshot";
        UMask = "0027";
      };
      script = ''
        ${pkgs.coreutils}/bin/mkdir -p ${clusterRoot}/Master
        ${pkgs.coreutils}/bin/install -m 0640 ${clusterIni} ${clusterRoot}/cluster.ini
        ${pkgs.coreutils}/bin/install -m 0640 ${masterIni} ${clusterRoot}/Master/server.ini
        ${pkgs.coreutils}/bin/chown -R dst:dst ${clusterRoot}
      '';
    };

    systemd.services.dst-master = {
      description = "Don't Starve Together trial server (Master)";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "dst-install-if-missing.service"
        "dst-prepare.service"
      ];
      after = [
        "network-online.target"
        "dst-install-if-missing.service"
        "dst-prepare.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "dst";
        Group = "dst";
        WorkingDirectory = "${gameDir}/bin64";
        Environment = [
          "HOME=${dataDir}"
          "LD_LIBRARY_PATH=${lib.makeLibraryPath [ curlGnutls ]}"
        ];
        ExecStart = lib.escapeShellArgs [
          "${pkgs.steam-run}/bin/steam-run"
          serverExecutable
          "-persistent_storage_root"
          dataDir
          "-conf_dir"
          "clusters"
          "-cluster"
          cfg.clusterName
          "-shard"
          "Master"
        ];
        Restart = "on-failure";
        RestartSec = "15s";
        TimeoutStopSec = "2min";
        KillSignal = "SIGINT";
        LimitNOFILE = 65536;
        CPUQuota = "200%";
        MemoryHigh = "1500M";
        MemoryMax = "2G";
        UMask = "0027";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ dataDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
      preStart = ''
        ${pkgs.coreutils}/bin/install -m 0400 ${token.path} ${clusterRoot}/cluster_token.txt
      '';
    };
  };
}
