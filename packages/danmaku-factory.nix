{
  lib,
  stdenv,
  fetchurl,
  pcre2,
}:

stdenv.mkDerivation {
  pname = "danmaku-factory";
  version = "1.70-3813e93";

  src = fetchurl {
    url = "https://github.com/hihkm/DanmakuFactory/archive/3813e93b13b087e95901d1822baf9c3540e3f3f6.tar.gz";
    hash = "sha256-R3DnXqvt3+TGEQ5l0hgADzVkcm5bb49wsVJBgEySc80=";
  };

  sourceRoot = "DanmakuFactory-3813e93b13b087e95901d1822baf9c3540e3f3f6";
  dontConfigure = true;
  buildInputs = [ pcre2 ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -std=gnu11 $(find src -type f -name '*.c' -print) \
      -I${pcre2.dev}/include -L${pcre2.out}/lib -lpcre2-8 \
      -o DanmakuFactory
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 DanmakuFactory "$out/bin/DanmakuFactory"
    install -Dm644 LICENSE "$out/share/licenses/danmaku-factory/LICENSE"
    runHook postInstall
  '';

  meta = {
    description = "Convert Bilibili danmaku files and render timelines";
    homepage = "https://github.com/hihkm/DanmakuFactory";
    license = lib.licenses.mit;
    mainProgram = "DanmakuFactory";
    platforms = [ "x86_64-linux" ];
  };
}
