#!/usr/bin/env nix-shell
#!nix-shell -i bash -p unzip curl jq common-updater-scripts
set -eo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bin_file="$(realpath ./osu-lazer-bin.nix)"

# Fetch latest release data with optional GitHub token authentication
curl_args=(-s)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

api_response="$(curl "${curl_args[@]}" "https://api.github.com/repos/ppy/osu/releases?per_page=1")"

# Check if GitHub returned an API error (e.g., rate limit exceeded)
if echo "$api_response" | jq -e '.message?' >/dev/null 2>&1; then
    echo "Error from GitHub API: $(echo "$api_response" | jq -r '.message')" >&2
    exit 1
fi

# Extract version name safely from array or object
new_version="$(echo "$api_response" | jq -r 'if type == "array" then .[0].name else .name // empty end')"

if [[ -z "$new_version" || "$new_version" == "null" ]]; then
    echo "Error: Could not extract version name from GitHub API response." >&2
    exit 1
fi

old_version="$(sed -nE 's/\s*version = "(.*)".*/\1/p' ./osu-lazer-bin.nix)"

echo "Latest version: $new_version"
if [[ "$new_version" == "$old_version" ]]; then
    echo "Already up to date."
    exit 0
fi

cd ../../..

echo "Updating osu-lazer-bin from $old_version to $new_version..."
sed -Ei.bak '/ *version = "/s/".+"/"'"$new_version"'"/' "$bin_file"
rm "$bin_file.bak"

for pair in \
    'x86_64-linux osu.AppImage'; do
    set -- $pair
    echo "Prefetching binary for $1..."
    prefetch_output=$(nix --extra-experimental-features nix-command store prefetch-file --json --hash-type sha256 "https://github.com/ppy/osu/releases/download/$new_version/$2")
    
    if [[ "$1" == *"darwin"* ]]; then
        store_path=$(jq -r '.storePath' <<<"$prefetch_output")
        tmpdir=$(mktemp -d)
        unzip -q "$store_path" -d "$tmpdir"
        hash=$(nix --extra-experimental-features nix-command hash path "$tmpdir")
        rm -r "$tmpdir"
    else
        hash=$(jq -r '.hash' <<<"$prefetch_output")
    fi
    
    echo "$1 ($2): hash = $hash"
    sed -Ei.bak '/ *'"$1"' = /{N;N; s@("sha256-)[^;"]+@"'"$hash"'@}' "$bin_file"
    rm "$bin_file.bak"
done
