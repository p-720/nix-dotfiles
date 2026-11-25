{
  config,
  lib,
  callPackage,
  fetchFromGitHub,
  nix-update-script,
  pkg-config,
  hyprland,
}@topLevelArgs:

let
  mkHyprlandPlugin = lib.extendMkDerivation {
    constructDrv = topLevelArgs.hyprland.stdenv.mkDerivation;

    extendDrvArgs =
      finalAttrs:
      {
        pluginName ? "",
        nativeBuildInputs ? [ ],
        buildInputs ? [ ],
        hyprland ? topLevelArgs.hyprland,
        ...
      }@args:

      {
        pname = "${pluginName}";
        nativeBuildInputs = [ pkg-config ] ++ nativeBuildInputs;
        buildInputs = [ hyprland ] ++ hyprland.buildInputs ++ buildInputs;
        meta = args.meta // {
          description = args.meta.description or "";
          longDescription =
            (args.meta.longDescription or "")
            + "\n\nPlugins can be installed via a plugin entry in the Hyprland NixOS or Home Manager options.";

          platforms = args.meta.platforms or hyprland.meta.platforms or [ ];
        };
      };
  };
in
mkHyprlandPlugin (finalAttrs: {
  pluginName = "hypr-darkwindow";
  # keep in step with the hyprland the plugin is built against: it pokes at
  # internal headers, so a mismatch is a compile error, not a runtime warning
  version = "0.56.2";

  src = fetchFromGitHub {
    owner = "micha4w";
    repo = "Hypr-DarkWindow";
    tag = "v${finalAttrs.version}";
    hash = "sha256-2upGTy7IRhrhxf+5VPjzrua8ebOtED6i8kSN8ka+ffg=";
  };

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib
    mv out/hypr-darkwindow.so $out/lib/libhypr-darkwindow.so

    runHook postInstall
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Hyprland Plugin to invert Colors of specific Windows!";
    homepage = "https://github.com/micha4w/Hypr-DarkWindow";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ anninzy ];
    platforms = lib.platforms.linux;
  };
})
