#!/usr/bin/env bash
# Exercise the selector used by publication: comparison must never inherit the
# production tag or point to the now-AL2023 root recipe while claiming Debian.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="$repo_root/scripts/select_batch_image_recipe.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export GITHUB_ENV="$work_dir/environment"

verify_recipe() {
    local recipe=$1 dockerfile=$2 base_os=$3 purpose=$4 tag=$5
    : > "$GITHUB_ENV"
    bash "$selector" "$recipe"
    [[ $(wc -l < "$GITHUB_ENV") -eq 5 ]]
    grep -Fxq "DOCKERFILE_PATH=$dockerfile" "$GITHUB_ENV"
    grep -Fxq "BASE_OS=$base_os" "$GITHUB_ENV"
    grep -Fxq "IMAGE_RECIPE=$recipe" "$GITHUB_ENV"
    grep -Fxq "PUBLICATION_PURPOSE=$purpose" "$GITHUB_ENV"
    grep -Fxq "IMAGE_TAG=$tag" "$GITHUB_ENV"
}
verify_recipe production-al2023 Dockerfile al2023 production "$GITHUB_SHA"
verify_recipe comparison-al2023 Dockerfile al2023 comparison "${GITHUB_SHA}-comparison-al2023"
verify_recipe comparison-debian experiments/issue296/Dockerfile.debian debian13 comparison "${GITHUB_SHA}-comparison-debian"
: > "$GITHUB_ENV"
bash "$selector"
grep -Fxq 'IMAGE_RECIPE=production-al2023' "$GITHUB_ENV"
grep -Fxq "IMAGE_TAG=$GITHUB_SHA" "$GITHUB_ENV"
for invalid in production-debian unknown $'comparison-al2023\nPUBLICATION_PURPOSE=production'; do
    : > "$GITHUB_ENV"
    if bash "$selector" "$invalid" >/dev/null 2>&1; then
        echo 'Invalid recipe unexpectedly accepted' >&2; exit 1
    fi
    [[ ! -s "$GITHUB_ENV" ]]
done
: > "$GITHUB_ENV"
if GITHUB_SHA=not-a-commit bash "$selector" >/dev/null 2>&1; then
    echo 'Invalid source commit unexpectedly accepted' >&2; exit 1
fi
[[ ! -s "$GITHUB_ENV" ]]
echo 'Batch image recipe regression checks passed'
