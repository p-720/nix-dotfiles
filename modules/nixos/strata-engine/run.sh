#!/bin/sh
# Start the Strata Control API server (serve/server.py) over the installed engine component.
# The engine component lives outside nix, under ~/.local/share/strata/components, and its folder
# name carries the version, so both the engine and the picture reader are resolved here at start
# rather than baked into the generated run config.
set -eu

control="${STRATA_CONTROL:?}"
ctl="$control"
template="${STRATA_CONFIG_TEMPLATE:?}"
components="${STRATA_COMPONENTS_DIR:-$HOME/.local/share/strata/components}"

engine_dir="${STRATA_ENGINE_DIR:-}"
if [ -z "$engine_dir" ]; then
    # Control's resolver picks the installed package for this card and verifies its files, the
    # same choice the app makes; a glob would take a higher version of the wrong backend.
    engine_exe=$(cd "$ctl" && "$ctl/python/bin/python3.12" -c \
        'from strata_control import engine_component; print(engine_component.resolve().exe)' 2>/dev/null) || engine_exe=""
    if [ -n "$engine_exe" ]; then
        engine_dir=$(dirname "$engine_exe")
    fi
fi
if [ -z "$engine_dir" ] || [ ! -x "$engine_dir/strata" ]; then
    echo "strata-engine: no engine component installed under $components/engine" >&2
    exit 5
fi

config_dir="${RUNTIME_DIRECTORY:-/tmp}"
config="$config_dir/config.json"
jq --arg exe "$engine_dir/strata" --arg vis "$engine_dir/strata-vision" --arg lib "$engine_dir" \
    '.exe = $exe | .lib_dirs = [$lib] | (if .vision then .vision.exe = $vis else . end)' \
    "$template" > "$config"

# Clients already hold the share-port key from state.json; a service without it must not listen
# beyond loopback.
state="${STRATA_STATE_FILE:-$HOME/.strata/data/state.json}"
key=""
if [ -r "$state" ]; then
    key=$(jq -r '.serving.apiKey // empty' "$state" 2>/dev/null || true)
fi
if [ -n "$key" ]; then
    export STRATA_API_KEY="$key"
    host="${STRATA_BIND:-127.0.0.1}"
else
    unset STRATA_API_KEY
    host=127.0.0.1
    echo "strata-engine: no API key in $state; listening on 127.0.0.1 only" >&2
fi

exec "$ctl/bin/strata" serve --profile "$config" \
    --host "$host" --port "${STRATA_PORT:-8080}"
