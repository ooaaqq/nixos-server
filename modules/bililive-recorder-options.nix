{ lib, ... }:
{
  options.ssvgg.bililiveRecorder = {
    enable = lib.mkEnableOption "BililiveRecorder with local ntfy event delivery";

    roomIds = lib.mkOption {
      type = lib.types.listOf lib.types.ints.positive;
      default = [ ];
      description = "Bilibili live rooms to monitor and record concurrently.";
    };

    node = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]{1,24}";
      description = "Short node label included in notifications.";
    };

    recordingCredentialFile = lib.mkOption {
      type = lib.types.path;
      description = "SOPS file containing the Bilibili cookies used by the recorder and live CDN helper.";
    };

    uploadCredentialFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "SOPS file containing the Biliup uploader cookies.json document.";
    };

    upload = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Upload completed sessions to Bilibili as private videos.";
    };

    cdnPriority = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9-]+");
      default = [ ];
      description = "Preferred Bilibili CDN IDs in order; recent reconnects cool down the previous CDN for five minutes. Empty uses recorder defaults.";
    };

    splitOnScriptTag = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Split recording files when FLV Script Tags suggest missing data.";
    };

    minimumUploadDuration = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Minimum segment duration in seconds for Bilibili submission; shorter originals remain available for backup.";
    };

    uploadTitle = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "{name} 直播回放 {title} {date}";
      description = "Private upload title template; supports name, title, date, room_id, and node placeholders.";
    };

    uploadDescription = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = ''
        直播间：https://live.bilibili.com/{room_id}
        由 {node} 自动录制上传。
      '';
      description = "Private upload description template with the same placeholders as uploadTitle.";
    };

    uploadTags = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [
        "录播"
        "直播回放"
      ];
      description = "Tags attached to private uploads.";
    };

    danmaku = lib.mkOption {
      type = lib.types.submodule {
        options = {
          roomIds = lib.mkOption {
            type = lib.types.listOf lib.types.ints.positive;
            default = [ ];
            description = "Rooms whose uploads include source and burned-danmaku parts.";
          };

          scrollTime = lib.mkOption {
            type = lib.types.ints.positive;
            default = 12;
            description = "Seconds for scrolling danmaku to cross the screen.";
          };

          density = lib.mkOption {
            type = lib.types.int;
            default = -1;
            description = "DanmakuFactory density; -1 requests non-overlapping scrolling comments.";
          };

          fontSize = lib.mkOption {
            type = lib.types.ints.positive;
            default = 32;
            description = "Danmaku font size in pixels.";
          };

          fontName = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "Noto Sans CJK SC";
            description = "Base font family used for danmaku.";
          };

          opacity = lib.mkOption {
            type = lib.types.ints.between 1 255;
            default = 255;
            description = "Opacity for ordinary danmaku, from 1 to 255.";
          };

          outline = lib.mkOption {
            type = lib.types.float;
            default = 0.8;
            description = "Thin text outline width in pixels.";
          };

          shadow = lib.mkOption {
            type = lib.types.ints.between 0 4;
            default = 0;
            description = "Danmaku shadow depth.";
          };

          showUsernames = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to include danmaku usernames.";
          };

          showMessageBoxes = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to render gifts, Super Chat, and guard message boxes.";
          };

          crf = lib.mkOption {
            type = lib.types.ints.between 0 51;
            default = 22;
            description = "x264 constant-rate-factor for burned-danmaku parts.";
          };

          maxRateKbit = lib.mkOption {
            type = lib.types.ints.positive;
            default = 18000;
            description = "Maximum x264 bitrate in kbit/s.";
          };

          bufferSizeKbit = lib.mkOption {
            type = lib.types.ints.positive;
            default = 36000;
            description = "x264 VBV buffer size in kbit/s.";
          };

          preset = lib.mkOption {
            type = lib.types.enum [
              "ultrafast"
              "superfast"
              "veryfast"
              "faster"
              "fast"
              "medium"
            ];
            default = "veryfast";
            description = "x264 speed and compression preset.";
          };

          threads = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4;
            description = "Maximum x264 worker threads per transcode.";
          };
        };
      };
      default = { };
      description = "Settings for burned-in danmaku uploads.";
    };

    collection = lib.mkOption {
      type = lib.types.submodule {
        options = {
          roomIds = lib.mkOption {
            type = lib.types.listOf lib.types.ints.positive;
            default = [ ];
            description = "Rooms whose uploaded archives should be added to a Bilibili collection.";
          };

          seasonTitle = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "露早录播";
            description = "Exact Bilibili collection title to match.";
          };

          sectionTitle = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "正片";
            description = "Exact section title within the collection.";
          };
        };
      };
      default = { };
      description = "Bilibili collection assignment after upload.";
    };

    ntfyServer = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:2586";
      description = "ntfy JSON publish endpoint.";
    };

    ntfyTopic = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_-]{1,64}";
      default = "inbox";
      description = "ntfy topic receiving recorder notifications.";
    };

    minimumFreeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 12;
      description = "Delete oldest closed recording segments below this free-space target.";
    };

    maximumAgeDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Maximum age of closed recording segments.";
    };
  };
}
