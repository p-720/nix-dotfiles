#!/usr/bin/env bash
# Compile and run the workspace-filter checks against the committed fixtures.
# GHC comes from the deployed dyre env so the aeson/text/map versions match the
# bar's. `mysystem` does not evaluate (an unrelated /mnt/md127 ssh key path), so
# the attribute is pinned to a host that does.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$HERE/../.." && pwd)
HOST=${HOST:-oldpc}
GHCENV=${GHCENV:-$(nix build --impure --no-link --print-out-paths "$REPO/.?submodules=1#nixosConfigurations.$HOST.config.modules.taffybar.ghcEnv")}
cd "$HERE"
mkdir -p out
PATH=$GHCENV/bin:$PATH ghc -outputdir out -o out/filter filter.hs
./out/filter fixtures/monitors.json fixtures/workspaces.json
