{ lib, runCommand, fetchurl, gnutar }:

let
  version = "0.1.58";

  # The official headless distribution (Strata Terminal): its own CPython 3.12, its own packages,
  # serve/server.py, strata_cli/strata_control. No desktop app, no system python.
  src = fetchurl {
    url = "https://github.com/Niko1221/Strata/releases/download/v0.2.12/strata-control-${version}-linux-x86_64.tar.gz";
    hash = "sha256-/M5Me5D1nE8Q8WGBpxkLOr55+q28nu84J4/cY14CiBc=";
  };
in
runCommand "strata-control-${version}" {
  nativeBuildInputs = [ gnutar ];
  meta = with lib; {
    description = "Strata Terminal: headless Strata server distribution (bundled Python 3.12)";
    homepage = "https://github.com/Niko1221/Strata";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
} ''
  # the archive is a flat tree (bin/strata, python/, serve/, strata_control/, ...), no top folder
  mkdir -p $out/terminal
  tar -xzf ${src} -C $out/terminal
''
