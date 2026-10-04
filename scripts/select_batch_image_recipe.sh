#!/usr/bin/env bash
# Resolve the reviewed production/comparison recipe without AWS or Docker.
set -euo pipefail
recipe="${1:-production-al2023}"
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || { echo 'GITHUB_SHA must be a full source commit' >&2; exit 2; }
: "${GITHUB_ENV:?GITHUB_ENV must name the workflow environment file}"
case "$recipe" in
    production-al2023|comparison-al2023)
        dockerfile=Dockerfile
        base_os=al2023
        ;;
    comparison-debian)
        dockerfile=experiments/issue296/Dockerfile.debian
        base_os=debian13
        ;;
    *) echo "Unknown image recipe: $recipe" >&2; exit 2 ;;
esac
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$repo_root/$dockerfile" ]] || { echo "Missing recipe: $dockerfile" >&2; exit 2; }
if [[ "$recipe" == production-al2023 ]]; then
    purpose=production
    tag="$GITHUB_SHA"
else
    purpose=comparison
    tag="${GITHUB_SHA}-${recipe}"
fi
printf 'DOCKERFILE_PATH=%s\nBASE_OS=%s\nIMAGE_RECIPE=%s\nIMAGE_TAG=%s\nPUBLICATION_PURPOSE=%s\n' \
    "$dockerfile" "$base_os" "$recipe" "$tag" "$purpose" >> "$GITHUB_ENV"
