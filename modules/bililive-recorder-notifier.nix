{ config, lib, pkgs, ... }:
let
  cfg = config.ssvgg.bililiveRecorder;
  common = import ./bililive-recorder-common.nix { inherit config lib pkgs; recorderCfg = cfg; };
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets = lib.mkIf cfg.upload {
      "bilibili/upload-cookies" = {
        sopsFile = cfg.uploadCredentialFile;
        key = "data";
        restartUnits = [ "bililive-recorder-notifier.service" ];
      };
    };

    systemd.services.bililive-recorder-notifier = {
      description = "BililiveRecorder webhook and ntfy notifier";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.concatStringsSep " " (
          [
            "${pkgs.python3}/bin/python3"
            "${common.notifierScript}"
            "--node ${lib.escapeShellArg cfg.node}"
            "--ntfy-server ${lib.escapeShellArg cfg.ntfyServer}"
            "--ntfy-topic ${lib.escapeShellArg cfg.ntfyTopic}"
            "--state /var/lib/bililive-recorder-notifier/state.json"
          ]
          ++ map (roomId: "--room-id ${toString roomId}") cfg.roomIds
          ++ lib.optionals cfg.upload [
            "--uploader ${common.biliup}/bin/biliup"
            "--uploader-cookie /var/lib/bililive-recorder-notifier/cookies.json"
            "--recording-root /var/lib/bililive-recorder/recordings"
            "--upload-line alia"
            "--upload-metadata ${common.uploadMetadata}"
          ]
          ++ lib.optionals (cfg.upload && cfg.minimumUploadDuration > 0) [
            "--minimum-upload-duration ${toString cfg.minimumUploadDuration}"
          ]
          ++ lib.optionals ((cfg.upload && cfg.minimumUploadDuration > 0) || cfg.danmaku.roomIds != [ ]) [
            "--ffprobe ${pkgs.ffmpeg-headless}/bin/ffprobe"
          ]
          ++ lib.optionals (cfg.danmaku.roomIds != [ ]) [
            "--danmaku-factory ${common.danmakuFactory}/bin/DanmakuFactory"
            "--ffmpeg ${pkgs.ffmpeg-headless}/bin/ffmpeg"
            "--fonts-directory ${common.danmakuFonts}"
          ]
        );
        LoadCredential = lib.mkIf cfg.upload "cookies.json:${common.uploadCredentials.path}";
        ExecStartPre = lib.mkIf cfg.upload "${common.prepareUploaderCredential}/bin/bililive-recorder-prepare-uploader-credential";
        Environment =
          lib.optionals cfg.upload [ "XDG_DATA_HOME=/var/lib/bililive-recorder-notifier" ]
          ++ lib.optionals (cfg.danmaku.roomIds != [ ]) [
            "FONTCONFIG_FILE=${common.fontconfigFile}"
            "XDG_CACHE_HOME=/var/lib/bililive-recorder-notifier/font-cache"
          ];
        WorkingDirectory = lib.mkIf cfg.upload "/var/lib/bililive-recorder-notifier";
        ReadWritePaths = lib.optionals (cfg.danmaku.roomIds != [ ]) [
          "/var/lib/bililive-recorder/recordings"
        ];
        User = "bililive-recorder";
        Group = "bililive-recorder";
        StateDirectory = "bililive-recorder-notifier";
        StateDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "15s";
        MemoryMax = if cfg.upload then "2G" else "96M";
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
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
