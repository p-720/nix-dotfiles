{
  lib,
  buildGoModule,
  fetchFromGitHub,
  versionCheckHook,
  nix-update-script,
  unstable,
}:
let
  buildGo = buildGoModule.override { go = unstable.go; };
in
buildGo (finalAttrs: {
  pname = "ketch";
  version = "0.20.1";

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "1broseidon";
    repo = "ketch";
    tag = "v${finalAttrs.version}";
    hash = "sha256-gmz+yi4OsqJaSfKJfHvSQCOemLLAkgXHtyiNNNgwdME=";
  };

  vendorHash = "sha256-FDsMmRXcTgqJGcYwRxsLkm5gtO7gZzQqVUpS6PZdzM8=";

  ldflags = [
    "-s"
    "-w"
    "-X github.com/1broseidon/ketch/cmd.version=${finalAttrs.version}"
  ];

  # fixes failing test https://github.com/1broseidon/ketch/blob/3722f58c1ff5c6b14b687ca3f925587996033536/cmd/config_golden_test.go#L33
  preCheck = ''
    unset ldflags
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "version";

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Fast, stateless CLI for web search and scrape. Built for AI agents.";
    homepage = "https://chain.sh/ketch/";
    changelog = "https://github.com/1broseidon/ketch/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      stephsi
    ];
    mainProgram = "ketch";
  };
})
