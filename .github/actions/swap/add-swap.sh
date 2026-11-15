#!/usr/bin/env bash
# Adds a swap file of $SWAP_GB GB on a Linux runner, on whichever of /mnt and / has
# more free space, so a build that needs more memory than the runner has gets slower
# instead of being killed.
set -euo pipefail

gb="${SWAP_GB:?}"
[[ $gb =~ ^[1-9][0-9]*$ ]] || { echo "::error::swap-gb must be a positive number, got '$gb'"; exit 2; }

avail_gb() { df --output=avail -BG "$1" 2> /dev/null | tail -1 | tr -dc 0-9; }

dir=/
if [[ -d /mnt && $(avail_gb /mnt) -gt $(avail_gb /) ]]; then dir=/mnt; fi
free=$(avail_gb "$dir")
# Leave room for the Nix store and the build directory.
if (( gb + 10 > free )); then
  echo "::error::${gb} GB of swap doesn't fit: $dir has ${free} GB free"
  exit 1
fi

file="${dir%/}/extra.swap"
sudo fallocate -l "${gb}G" "$file"
sudo chmod 600 "$file"
sudo mkswap "$file" > /dev/null
sudo swapon "$file"

free -h
swapon --show
