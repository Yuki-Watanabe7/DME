#!/usr/bin/env bash
# Regression checks for immutable-image provenance and comparison publication.
# No AWS or Docker daemon: use deterministic CLI responses for an older image
# while the host's base tag represents a newer digest.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
mkdir "$work_dir/bin"
cat >"$work_dir/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1 $2" = 'image inspect' ]; then
    case "$4" in
        '{{.Created}}') echo 2026-10-01T00:00:00Z ;;
        '{{.Size}}') echo 123456 ;;
        *image.source*) echo https://github.com/Yuki-Watanabe7/DME ;;
        *image.revision*) echo "$GITHUB_SHA" ;;
        *image.version*) echo "$IMAGE_VERSION" ;;
        *image.base.name*) echo public.ecr.aws/amazonlinux/amazonlinux:2023-minimal ;;
        *image.base.digest*) printf 'sha256:%064d\n' 1 ;;
        *RepoDigests*) printf 'new-host-base@sha256:%064d\n' 2 ;;
        *) exit 2 ;;
    esac
elif [ "$1" = run ]; then
    case "$*" in
        *PRETTY_NAME*) echo 'Amazon Linux 2023' ;;
        *GNU_LIBC_VERSION*) echo 'glibc 2.34' ;;
        *bundled_libraries*) echo '{"name":"julia","version":"1.13.1","bundled_libraries":{}}' ;;
        *) exit 2 ;;
    esac
else
    exit 2
fi
MOCK
cat >"$work_dir/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
    describe-images)
        case "$*" in
            *'imageDetails[0]'*) echo '{"imageManifestMediaType":"application/vnd.docker.distribution.manifest.v2+json","imageSizeInBytes":45678}' ;;
            *'imageDetails[].imageSizeInBytes'*) echo '[45678,23456]' ;;
            *) exit 2 ;;
        esac
        ;;
    describe-image-scan-findings) cat "$SCAN_FIXTURE" ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$work_dir/bin/docker" "$work_dir/bin/aws"
export PATH="$work_dir/bin:$PATH"
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
IMAGE_DIGEST="sha256:$(printf '%064d' 3)"
export IMAGE_DIGEST
export ECR_REPOSITORY_URL=123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/dme
export AWS_REGION=ap-northeast-1 IMAGE_VERSION=0.1.0+aaaaaaaaaaaa
export SCAN_FIXTURE="$work_dir/scan.json" EVIDENCE_PATH="$work_dir/evidence.json"
export SCAN_MAX_ATTEMPTS=1 SCAN_POLL_SECONDS=0
export GITHUB_STEP_SUMMARY="$work_dir/summary.md"
export PUBLICATION_PURPOSE=comparison IMAGE_TAG="${GITHUB_SHA}-comparison-al2023"
echo '{"imageScanStatus":{"status":"COMPLETE"},"imageScanFindings":{"imageScanCompletedAt":"2026-10-02T00:00:00Z","findingSeverityCounts":{},"findings":[]}}' >"$SCAN_FIXTURE"
bash "$repo_root/scripts/record_image_publication.sh"
jq -e --arg sha "$GITHUB_SHA" --arg old_base "public.ecr.aws/amazonlinux/amazonlinux:2023-minimal@sha256:$(printf '%064d' 1)" '
    .source_commit == $sha and .publication_purpose == "comparison"
    and (.image_tag | endswith($sha + "-comparison-al2023"))
    and .base_images[0].resolved_digest == $old_base
    and .deployment_status == "approved" and .glibc == "glibc 2.34"
    and .image_size_bytes == 123456
    and .ecr_image_size_bytes == 45678
    and .ecr_repository_image_bytes_upper_bound == 69134
    and .scan.completed_at == "2026-10-02T00:00:00Z"' "$EVIDENCE_PATH" >/dev/null
grep -q "$IMAGE_TAG" "$GITHUB_STEP_SUMMARY"

# The default production tag and fail-closed scan gate keep their meaning.
unset PUBLICATION_PURPOSE IMAGE_TAG
echo '{"imageScanStatus":{"status":"COMPLETE"},"imageScanFindings":{"findingSeverityCounts":{"HIGH":1},"findings":[{"name":"CVE-test-high","severity":"HIGH"}]}}' >"$SCAN_FIXTURE"
if bash "$repo_root/scripts/record_image_publication.sh"; then
    echo 'HIGH finding unexpectedly approved' >&2; exit 1
fi
jq -e --arg tag "${ECR_REPOSITORY_URL}:${GITHUB_SHA}" '
    .image_tag == $tag and .publication_purpose == "production"
    and .deployment_status == "blocked"
    and .scan.blocker_findings[0].cve == "CVE-test-high"
    and .exceptions == []' "$EVIDENCE_PATH" >/dev/null
echo '{"imageScanStatus":{"status":"IN_PROGRESS"}}' >"$SCAN_FIXTURE"
if bash "$repo_root/scripts/record_image_publication.sh"; then
    echo 'Pending scan unexpectedly approved' >&2; exit 1
fi
jq -e '.deployment_status == "pending"' "$EVIDENCE_PATH" >/dev/null
echo 'Image publication regression checks passed'
