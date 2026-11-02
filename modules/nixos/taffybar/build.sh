#!/usr/bin/env bash
# Manual rebuild of the cached taffybar binary. The running bar already
# auto-recompiles on config change (dyre); use this when no session is up or
# after an out-of-band edit.
#
# -rtsopts is mandatory: the taffybar launcher runs the binary with
# +RTS -I0 -V0 -RTS, and a binary linked without -rtsopts exits 1 at startup
# ("Most RTS options are disabled") — the bar then crash-loops at login.
#
# The ghc path must match modules.taffybar.ghcEnv; a nixos-rebuild can change
# the store path — update it here if this starts failing.
set -euo pipefail
cd "$(dirname "$0")"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/taffybar"
/nix/store/nvdmcr80bp6ry5ls5micaxn5cw78m0bc-ghc-9.10.3-with-packages/bin/ghc \
  --make -threaded -rtsopts taffybar.hs \
  -outputdir "$cache" \
  -o "$cache/taffybar-linux-x86_64.taffybar-wrapped"
