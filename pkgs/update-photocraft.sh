#!/usr/bin/env bash
# Update pkgs/photoccraft.nix to the latest GitHub release.
# Computes both the fetchFromGitHub `hash` and the cargo vendor `cargoHash`.
set -eo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

nix_file="./photocraft.nix"
owner="storytold"
repo="photocraft"

# Fetch latest release data with optional GitHub token authentication
curl_args=(-s)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

api_response="$(curl "${curl_args[@]}" "https://api.github.com/repos/$owner/$repo/releases/latest")"

# Check if GitHub returned an API error (e.g., rate limit exceeded)
if echo "$api_response" | jq -e '.message?' >/dev/null 2>&1; then
    echo "Error from GitHub API: $(echo "$api_response" | jq -r '.message')" >&2
    exit 1
fi

# Tag looks like v0.6.0, the nix version is 0.6.0
new_version="$(echo "$api_response" | jq -r '.tag_name | ltrimstr("v")')"

if [[ -z "$new_version" || "$new_version" == "null" ]]; then
    echo "Error: Could not extract version from GitHub API response." >&2
    exit 1
fi

old_version="$(sed -nE 's/^ *version = "(.*)";$/\1/p' "$nix_file")"

echo "Latest version: $new_version (current: $old_version)"
if [[ "$new_version" == "$old_version" ]]; then
    echo "Already up to date."
    exit 0
fi

echo "Updating photocraft from $old_version to $new_version..."
sed -Ei.bak '/^ *version = "/s/".+"/"'"$new_version"'"/' "$nix_file"
rm "$nix_file.bak"

# Recompute the fetchFromGitHub hash from the release tarball
echo "Prefetching source for v$new_version..."
src_hash="$(nix --extra-experimental-features nix-command store prefetch-file --json --unpack \
    "https://github.com/$owner/$repo/archive/refs/tags/v$new_version.tar.gz" | jq -r '.hash')"

echo "src hash = $src_hash"
sed -Ei.bak '/^ *hash = "";$/s/"";/"'"$src_hash"'";/' "$nix_file"
rm "$nix_file.bak"

# Recompute the cargo vendor hash. fetchCargoVendor vendors the crates.io deps
# without compiling anything, which is far cheaper than building the package.
echo "Computing cargo vendor hash..."
cargo_hash="$(nix --extra-experimental-features nix-command build --impure --no-link \
    --expr "(let pkgs = import <nixpkgs> { }; src = pkgs.fetchFromGitHub { owner = \"$owner\"; repo = \"$repo\"; tag = \"v$new_version\"; hash = \"$src_hash\"; }; in pkgs.rustPlatform.fetchCargoVendor { inherit src; hash = \"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\"; })" \
    2>&1 | sed -nE 's/^ +got: +(.*)$/\1/p' | head -1)"

if [[ -z "$cargo_hash" ]]; then
    echo "Error: could not compute cargoHash (fetchCargoVendor did not report a mismatch)." >&2
    exit 1
fi

echo "cargoHash = $cargo_hash"
sed -Ei.bak '/^ *cargoHash = "";$/s/"";/"'"$cargo_hash"'";/' "$nix_file"
rm "$nix_file.bak"

echo "Done. Verify with: nix build .#nixosConfigurations.mysystem.pkgs.my.photocraft"