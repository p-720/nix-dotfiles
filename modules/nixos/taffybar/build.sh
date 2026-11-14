#!/usr/bin/env bash
# Manual rebuild of the cached taffybar binary. The running bar already
# auto-recompiles on config change (dyre); use this when no session is up or
# after an out-of-band edit.
#
# -rtsopts is mandatory: the taffybar launcher runs the binary with
# +RTS -I0 -V0 -RTS, and a binary linked without -rtsopts exits 1 at startup
# ("Most RTS options are disabled") — the bar then crash-loops at login.
#
# The ghc must match modules.taffybar.ghcEnv (its package set is what the
# imports compile against). Resolved from the eval rather than hardcoded: any
# rebuild moves the store path. Pass one as $1 to override.
set -euo pipefail
cd "$(dirname "$0")"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/taffybar"
ghc="${1:-$(cd /etc/nixos && nix build --impure --no-link --print-out-paths \
  .#nixosConfigurations.mysystem.config.modules.taffybar.ghcEnv)}"
"$ghc/bin/ghc" \
  --make -threaded -rtsopts taffybar.hs \
  -outputdir "$cache" \
  -o "$cache/taffybar-linux-x86_64.taffybar-wrapped"
