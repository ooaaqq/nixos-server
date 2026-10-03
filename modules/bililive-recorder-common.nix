{ config, lib, pkgs, recorderCfg }:
let
  cfg = recorderCfg;
  recordingCredentials = config.sops.secrets."bilibili/recording-cookies";
  uploadCredentials = config.sops.secrets."bilibili/upload-cookies";
  biliup = pkgs.callPackage ../packages/biliup.nix { };
  danmakuFactory = pkgs.callPackage ../packages/danmaku-factory.nix { };
  monochromeEmojiFont = pkgs.callPackage ../packages/noto-emoji-mono.nix { };
  danmakuFonts = pkgs.runCommand "bililive-recorder-danmaku-fonts" { } ''
    mkdir -p "$out"
    ln -s "${pkgs.noto-fonts-cjk-sans}/share/fonts/opentype/noto-cjk/NotoSansCJK-VF.otf.ttc" \
      "$out/NotoSansCJK-VF.otf.ttc"
    ln -s "${monochromeEmojiFont}/share/fonts/opentype/noto/NotoEmoji.otf" \
      "$out/NotoEmoji.otf"
  '';
  fontconfigFile = pkgs.makeFontsConf {
    fontDirectories = [ danmakuFonts ];
  };
  recorderConfig = pkgs.writeText "bililive-recorder-config.json" (
    builtins.toJSON {
      version = 3;
      global = {
        RecordMode = {
          HasValue = true;
          Value = 0;
        };
        CuttingMode = {
          HasValue = true;
          Value = 1;
        };
        CuttingNumber = {
          HasValue = true;
          Value = 60;
        };
        RecordDanmaku = {
          HasValue = true;
          Value = true;
        };
        RecordDanmakuRaw = {
          HasValue = true;
          Value = true;
        };
        RecordDanmakuGift = {
          HasValue = true;
          Value = true;
        };
        SaveStreamCover = {
          HasValue = true;
          Value = true;
        };
        RecordingQuality = {
          HasValue = true;
          Value = "avc30000,hevc30000,avc25000,hevc25000,avc20000,hevc20000,avc15000,hevc15000,avc10000,hevc10000,avc400,hevc400,avc250,hevc250";
        };
        FileNameRecordTemplate = {
          HasValue = true;
          Value = ''{{ roomId }}-{{ name }}/{{ "now" | time_zone: "Asia/Shanghai" | format_date: "yyyyMMdd-HHmmss" }}-{{ qn | format_qn }}-{{ title }}.flv'';
        };
        FlvProcessorSplitOnScriptTag = {
          HasValue = true;
          Value = cfg.splitOnScriptTag;
        };
        UserScript = {
          HasValue = true;
          Value =
            if cfg.cdnPriority == [ ] then
              ""
            else
              builtins.replaceStrings [ "__CDN_PRIORITY__" ] [ (builtins.toJSON cfg.cdnPriority) ] (
                builtins.readFile ../packages/bililive-recorder-cdn.js
              );
        };
        NetworkTransportAllowedAddressFamily = {
          HasValue = true;
          Value = 1;
        };
        TimingCheckInterval = {
          HasValue = true;
          Value = 30;
        };
        WebHookUrlsV2 = {
          HasValue = true;
          Value = "http://127.0.0.1:22357/webhook";
        };
        Cookie = {
          HasValue = true;
          Value = "";
        };
      };
      rooms = map (roomId: {
        RoomId = {
          HasValue = true;
          Value = roomId;
        };
        AutoRecord = {
          HasValue = true;
          Value = true;
        };
      }) cfg.roomIds;
    }
  );
  uploadMetadata = pkgs.writeText "biliup-upload-metadata.json" (
    builtins.toJSON {
      title = cfg.uploadTitle;
      description = cfg.uploadDescription;
      tags = cfg.uploadTags;
      danmaku = {
        room_ids = cfg.danmaku.roomIds;
        settings = {
          scroll_time = cfg.danmaku.scrollTime;
          density = cfg.danmaku.density;
          font_size = cfg.danmaku.fontSize;
          font_name = cfg.danmaku.fontName;
          opacity = cfg.danmaku.opacity;
          outline = cfg.danmaku.outline;
          shadow = cfg.danmaku.shadow;
          show_usernames = cfg.danmaku.showUsernames;
          show_message_boxes = cfg.danmaku.showMessageBoxes;
          crf = cfg.danmaku.crf;
          max_rate_kbit = cfg.danmaku.maxRateKbit;
          buffer_size_kbit = cfg.danmaku.bufferSizeKbit;
          preset = cfg.danmaku.preset;
          threads = cfg.danmaku.threads;
        };
      };
      collection =
        if cfg.collection.roomIds == [ ] then
          null
        else
          {
            room_ids = cfg.collection.roomIds;
            season_title = cfg.collection.seasonTitle;
            section_title = cfg.collection.sectionTitle;
          };
    }
  );
  prepareConfig = pkgs.writeShellApplication {
    name = "bililive-recorder-prepare-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      install -d -m 0700 "$STATE_DIRECTORY/recordings" "$STATE_DIRECTORY/logs"
      cookie=$(jq --exit-status --raw-output \
        '[.cookie_info.cookies[] | select(
          (.name | type == "string") and (.value | type == "string")
        ) | "\(.name)=\(.value)"] | if length > 0 then join("; ") else error("empty cookie set") end' \
        "$CREDENTIALS_DIRECTORY/cookies.json")
      jq --arg cookie "$cookie" '
        .global.Cookie.Value = $cookie |
        if .global.UserScript.Value != "" then
          .global.UserScript.Value = ("const recorderCookie = " + ($cookie | tojson) + ";\n" + .global.UserScript.Value)
        else . end
      ' \
        ${recorderConfig} > "$RUNTIME_DIRECTORY/config.json.new"
      chmod 0600 "$RUNTIME_DIRECTORY/config.json.new"
      mv "$RUNTIME_DIRECTORY/config.json.new" "$RUNTIME_DIRECTORY/config.json"
    '';
  };
  prepareUploaderCredential = pkgs.writeShellApplication {
    name = "bililive-recorder-prepare-uploader-credential";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      source="$CREDENTIALS_DIRECTORY/cookies.json"
      destination="$STATE_DIRECTORY/cookies.json"
      marker="$STATE_DIRECTORY/cookies.source.sha256"
      jq --exit-status \
        '.cookie_info.cookies | type == "array" and length > 0' \
        "$source" >/dev/null
      source_hash=$(sha256sum "$source" | cut -d ' ' -f 1)
      if [[ ! -s "$destination" ]] \
        || [[ ! -r "$destination" ]] \
        || [[ ! -f "$marker" ]] \
        || [[ ! -r "$marker" ]] \
        || [[ "$(<"$marker")" != "$source_hash" ]]; then
        install -m 0600 "$source" "$destination.new"
        printf '%s\n' "$source_hash" > "$marker.new"
        chmod 0600 "$marker.new"
        mv -f "$destination.new" "$destination"
        mv -f "$marker.new" "$marker"
      fi
    '';
  };
  cleanup = pkgs.writeShellApplication {
    name = "bililive-recorder-cleanup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      recording_dir=/var/lib/bililive-recorder/recordings
      minimum_free_bytes=$((${toString cfg.minimumFreeGiB} * 1024 * 1024 * 1024))
      maximum_age_minutes=$((${toString cfg.maximumAgeDays} * 24 * 60))
      install -d -m 0700 "$recording_dir"

      remove_bundle() {
        local flv="$1"
        local base="''${flv%.flv}"
        rm -f -- "$flv" "$base.xml" "$base.cover.jpg" \
          "$base-纯净版.flv" "$base-弹幕版.ass" "$base-弹幕版.partial.mp4" \
          "$base-弹幕版.mp4"
      }

      while IFS= read -r -d "" flv; do
        remove_bundle "$flv"
      done < <(find "$recording_dir" -type f -name '*.flv' \
        -mmin "+$maximum_age_minutes" -print0)

      while IFS= read -r -d "" entry; do
        available=$(df --output=avail -B1 "$recording_dir" | tail -n 1 | tr -d ' ')
        if ((available >= minimum_free_bytes)); then
          break
        fi
        remove_bundle "''${entry#* }"
      done < <(find "$recording_dir" -type f -name '*.flv' -mmin +10 \
        -printf '%T@ %p\0' | sort -z -n)

      available=$(df --output=avail -B1 "$recording_dir" | tail -n 1 | tr -d ' ')
      if ((available < minimum_free_bytes)); then
        echo "recording disk remains below the free-space target; no closed segment is safe to remove" >&2
      fi
    '';
  };
  notifierScript = ../packages/bililive-recorder-notifier.py;
in
{
  inherit recordingCredentials uploadCredentials biliup danmakuFactory danmakuFonts fontconfigFile recorderConfig uploadMetadata prepareConfig prepareUploaderCredential cleanup notifierScript;
}
