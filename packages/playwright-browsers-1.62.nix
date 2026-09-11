{
  lib,
  stdenv,
  fetchzip,
  linkFarm,
  makeFontsConf,
  makeWrapper,
  autoPatchelfHook,
  patchelf,
  patchelfUnstable,
  alsa-lib,
  at-spi2-atk,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gobject-introspection,
  libGL,
  libgbm,
  libgcc,
  libxkbcommon,
  nspr,
  nss,
  pango,
  pciutils,
  systemd,
  vulkan-loader,
  libxrandr,
  libxfixes,
  libxext,
  libxdamage,
  libxcomposite,
  libx11,
  libxcb,
  liberation_ttf,
  noto-fonts-cjk-sans,
  noto-fonts-color-emoji,
}:
let
  revision = "1234";
  browserVersion = "151.0.7922.34";
  baseUrl = "https://cdn.playwright.dev/builds/cft/${browserVersion}/linux64";
  fontconfigFile = makeFontsConf {
    fontDirectories = [
      liberation_ttf
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
    ];
  };

  chromium = stdenv.mkDerivation {
    pname = "playwright-chromium";
    version = browserVersion;
    src = fetchzip {
      url = "${baseUrl}/chrome-linux64.zip";
      stripRoot = true;
      hash = "sha256-3/o8ZFVeL/YDuO+aax+qcm6xv77AX6Vl6meP+S05cTk=";
    };
    nativeBuildInputs = [
      autoPatchelfHook
      patchelf
      makeWrapper
    ];
    buildInputs = [
      alsa-lib
      at-spi2-atk
      atk
      cairo
      cups
      dbus
      expat
      glib
      gobject-introspection
      libgbm
      libgcc
      libxkbcommon
      nspr
      nss
      pango
      stdenv.cc.cc.lib
      systemd
      libx11
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxrandr
      libxcb
    ];
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/chrome-linux64"
      cp -R . "$out/chrome-linux64"
      wrapProgram "$out/chrome-linux64/chrome" \
        --set-default SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
        --set-default FONTCONFIG_FILE ${fontconfigFile}
      runHook postInstall
    '';
    appendRunpaths = lib.makeLibraryPath [
      libGL
      vulkan-loader
      pciutils
    ];
    postFixup = ''
      rm "$out/chrome-linux64/libvulkan.so.1"
      ln -s "${lib.getLib vulkan-loader}/lib/libvulkan.so.1" \
        "$out/chrome-linux64/libvulkan.so.1"
    '';
  };

  chromiumHeadlessShell = stdenv.mkDerivation {
    pname = "playwright-chromium-headless-shell";
    version = browserVersion;
    src = fetchzip {
      url = "${baseUrl}/chrome-headless-shell-linux64.zip";
      stripRoot = false;
      hash = "sha256-2w0Ul3tpzrVkfGHIbQGwEsCRmVUUy3OAShGhuoH6Rmw=";
    };
    nativeBuildInputs = [
      autoPatchelfHook
      patchelfUnstable
    ];
    buildInputs = [
      alsa-lib
      at-spi2-atk
      expat
      glib
      libxcomposite
      libxdamage
      libxfixes
      libxrandr
      libgbm
      libgcc
      libxkbcommon
      nspr
      nss
    ];
    buildPhase = ''
      cp -R . "$out"
    '';
  };
in
linkFarm "playwright-browsers-1.62.0" {
  "chromium-${revision}" = chromium;
  "chromium_headless_shell-${revision}" = chromiumHeadlessShell;
}
// {
  inherit fontconfigFile;
}
