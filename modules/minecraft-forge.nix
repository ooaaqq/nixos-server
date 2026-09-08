{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ssvgg.minecraft;
  dataDir = "/var/lib/minecraft";
  java = pkgs.jdk17_headless;
in
{
  options.ssvgg.minecraft.enable = lib.mkEnableOption "the restored Forge Minecraft server";

  config = lib.mkIf cfg.enable {
    users.groups.minecraft = { };
    users.users.minecraft = {
      isSystemUser = true;
      group = "minecraft";
      home = dataDir;
      createHome = true;
    };

    networking.firewall = {
      allowedTCPPorts = [ 25565 ];
      allowedUDPPorts = [ 25565 ];
    };

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0750 minecraft minecraft - -"
    ];

    systemd.services.minecraft = {
      description = "Minecraft Forge server";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig = {
        StartLimitIntervalSec = "5min";
        StartLimitBurst = 3;
      };
      environment.HOME = dataDir;
      serviceConfig = {
        User = "minecraft";
        Group = "minecraft";
        WorkingDirectory = dataDir;
        ExecStartPre = [ "+${pkgs.coreutils}/bin/chown -R minecraft:minecraft ${dataDir}" ];
        ExecStart = lib.escapeShellArgs [
          "${java}/bin/java"
          "-Djava.net.preferIPv4Stack=true"
          "-Xms4G"
          "-Xmx6G"
          "-XX:+UseG1GC"
          "-XX:+ParallelRefProcEnabled"
          "-XX:MaxGCPauseMillis=200"
          "-XX:+DisableExplicitGC"
          "-XX:+PerfDisableSharedMem"
          "-XX:G1ReservePercent=20"
          "-XX:InitiatingHeapOccupancyPercent=15"
          "@libraries/net/minecraftforge/forge/1.20.1-47.3.33/unix_args.txt"
          "nogui"
        ];
        Restart = "on-failure";
        RestartSec = "15s";
        TimeoutStopSec = "2min";
        KillSignal = "SIGINT";
        LimitNOFILE = 65536;
        UMask = "0007";
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
    };
  };
}
