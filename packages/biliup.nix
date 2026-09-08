{
  lib,
  stdenvNoCC,
  fetchurl,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "biliup";
  version = "1.2.4";

  src = fetchurl {
    url = "https://github.com/biliup/biliup/releases/download/v${finalAttrs.version}/biliupR-v${finalAttrs.version}-x86_64-linux-musl.tar.xz";
    hash = "sha256-D3OoyQ179h3KoHIDZY83X3OGCOXcV0WizLv8cYe3g+M=";
  };

  sourceRoot = "biliupR-v${finalAttrs.version}-x86_64-linux-musl";

  installPhase = ''
    runHook preInstall
    install -Dm755 biliup "$out/bin/biliup"
    runHook postInstall
  '';

  meta = {
    description = "Bilibili video uploader CLI";
    homepage = "https://github.com/biliup/biliup";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "biliup";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
})
