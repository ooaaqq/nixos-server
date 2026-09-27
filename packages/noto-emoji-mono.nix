{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  revision = "663e980a046998972df2c3a2fb571576d1e07884";
in
stdenvNoCC.mkDerivation {
  pname = "noto-emoji-mono";
  version = "13.1";

  dontUnpack = true;

  font = fetchurl {
    url = "https://raw.githubusercontent.com/adobe-fonts/noto-emoji-svg/${revision}/fonts/NotoEmoji.otf";
    hash = "sha256-NMscO8ZSBdKReR89pxZtebqLmOltH5tZWMeynLV3Vbo=";
  };
  licenseFile = fetchurl {
    url = "https://raw.githubusercontent.com/adobe-fonts/noto-emoji-svg/${revision}/fonts/LICENSE";
    hash = "sha256-anP5VBwt50FYwOfPawpY73dPWngL8ZHy1+ycxT7+K/I=";
  };

  installPhase = ''
    runHook preInstall
    install -Dm644 "$font" "$out/share/fonts/opentype/noto/NotoEmoji.otf"
    install -Dm644 "$licenseFile" "$out/share/licenses/noto-emoji-mono/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Monochrome Noto Emoji font with Unicode 13.1 glyph coverage";
    homepage = "https://github.com/adobe-fonts/noto-emoji-svg";
    license = lib.licenses.ofl;
    platforms = lib.platforms.all;
  };
}
