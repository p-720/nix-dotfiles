{ appimageTools
, fetchurl
, lib
}:

appimageTools.wrapType2 rec {
  pname = "strata";
  version = "0.2.11";

  src = fetchurl {
    url = "https://github.com/Niko1221/Strata/releases/download/v${version}/Strata-${version}-linux-x86_64.AppImage";
    sha256 = "sha256-nKyb5/gc6Syn+wuDkYC+xz1FS4rksrwKckwGeMLiEZ4=";
  };

  # bundled gstreamer libs in the AppImage link libstdc++, absent from the
  # default FHS env
  extraPkgs = pkgs: [ pkgs.stdenv.cc.cc.lib ];

  meta = with lib; {
    description = "Local AI inference engine with an OpenAI/Anthropic-compatible localhost API";
    homepage = "https://github.com/Niko1221/Strata";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "strata-desktop";
  };
}
