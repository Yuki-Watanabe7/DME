#!/usr/bin/env bash
# Build and exercise the ECS-compatible DME batch image without a source mount.
# Usage: scripts/verify_batch_container.sh [image-tag]
set -euo pipefail

image_tag="${1:-dme-batch:verify}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$(mktemp -d)"

cleanup() {
    rm -rf "$output_dir"
}
trap cleanup EXIT

# Docker bind mounts retain host ownership. Allow the image's fixed non-root
# UID (10001) to write this temporary stand-in for an ECS-provisioned volume.
chmod 0777 "$output_dir"

docker build --tag "$image_tag" "$repo_root"

test "$(docker image inspect --format '{{.Config.User}}' "$image_tag")" = "10001:10001"
test "$(docker run --rm --entrypoint id "$image_tag" -u)" = "10001"
test "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image_tag")" = '["dme"]'

# Only the runtime-supplied artifact mount is mounted: the image must contain
# all source and dependencies required to execute the simulation.
docker run --rm \
    --mount "type=bind,src=$output_dir,dst=/var/lib/dme/artifacts" \
    "$image_tag" simulate solow --periods 100

test -f "$output_dir/simulation/solow/simulation.json"

set +e
docker run --rm "$image_tag" simulate unsupported --out /var/lib/dme/artifacts
status=$?
set -e
test "$status" -eq 2

echo "DME batch container verification passed: $image_tag"
