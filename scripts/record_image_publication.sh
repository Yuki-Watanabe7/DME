#!/usr/bin/env bash
# Record the publication evidence of a DME batch image digest (Issue #252, ADR 0026,
# PAP ADR 0017 A7/A8) and decide whether it is admissible.
#
# Called by .github/workflows/publish-batch-image.yml after the image was pushed and
# pulled back from ECR. Required environment:
#
#   GITHUB_SHA           source commit (= the image tag and OCI revision label)
#   IMAGE_DIGEST         pushed manifest digest (sha256:...)
#   ECR_REPOSITORY_URL   <account>.dkr.ecr.<region>.amazonaws.com/<repository>
#   AWS_REGION           region of the repository
#   IMAGE_VERSION        OCI version label
#
# Writes image-publication.json (A8 evidence) and appends a summary to
# GITHUB_STEP_SUMMARY when set. Exits 0 only when the digest has a COMPLETE ECR scan
# without HIGH or CRITICAL findings; the evidence is written in every case.
#
# PLATFORM (default linux/amd64) is the published platform. LOCAL_IMAGE_REFERENCE
# only lets a dry run inspect a local image instead of the pulled ECR digest.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="${EVIDENCE_PATH:-image-publication.json}"
max_attempts="${SCAN_MAX_ATTEMPTS:-40}"
poll_seconds="${SCAN_POLL_SECONDS:-15}"
platform="${PLATFORM:-linux/amd64}"

: "${GITHUB_SHA:?}" "${IMAGE_DIGEST:?}" "${ECR_REPOSITORY_URL:?}" "${AWS_REGION:?}" "${IMAGE_VERSION:?}"
image_tag="${IMAGE_TAG:-$GITHUB_SHA}"
publication_purpose="${PUBLICATION_PURPOSE:-production}"
case "$publication_purpose" in production|comparison) ;; *) echo "invalid PUBLICATION_PURPOSE" >&2; exit 2 ;; esac
[[ "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "invalid IMAGE_DIGEST" >&2; exit 2; }
repository="${ECR_REPOSITORY_URL#*/}"
image_reference="${ECR_REPOSITORY_URL}@${IMAGE_DIGEST}"
inspected_image="${LOCAL_IMAGE_REFERENCE:-$image_reference}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-Yuki-Watanabe7/DME}/actions/runs/${GITHUB_RUN_ID:-local}"

# --- What the digest contains (A8: base references, OS release, runtime) ---------
label() {
    docker image inspect --format "{{index .Config.Labels \"org.opencontainers.image.$1\"}}" \
        "$inspected_image"
}
built_at="$(docker image inspect --format '{{.Created}}' "$inspected_image")"
image_size="$(docker image inspect --format '{{.Size}}' "$inspected_image")"
os_release="$(docker run --rm --platform "$platform" --entrypoint /bin/sh "$inspected_image" \
    -c '. /etc/os-release; echo "$PRETTY_NAME"')"
glibc="$(docker run --rm --platform "$platform" --entrypoint /bin/sh "$inspected_image" \
    -c 'getconf GNU_LIBC_VERSION')"
# Julia and the libraries it bundles live outside the dpkg database, so ECR basic
# scanning never sees them. Their versions are recorded so that Julia security
# releases can be tracked against this digest.
runtime_json="$(docker run --rm --platform "$platform" --entrypoint julia "$inspected_image" \
    --startup-file=no -e '
        import LibCURL_jll, LibGit2_jll, LibSSH2_jll, OpenSSL_jll, Zlib_jll
        libs = [string(nameof(m)) => string(pkgversion(m))
                for m in (LibCURL_jll, LibGit2_jll, LibSSH2_jll, OpenSSL_jll, Zlib_jll)]
        print("{\"name\":\"julia\",\"version\":\"", VERSION, "\",\"bundled_libraries\":{",
              join(["\"$k\":\"$v\"" for (k, v) in libs], ","), "}}")')"
# Read the base provenance from the exact image, even when its immutable tag is
# reused. The Docker host's base tag can have moved since the original build.
base_reference="$(label base.name)"
base_digest="$(label base.digest)"
[[ "$base_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "missing resolved base digest label" >&2; exit 2; }
base_images="$(jq -n --arg reference "$base_reference" --arg resolved "${base_reference}@${base_digest}" \
    '[{reference: $reference, resolved_digest: $resolved}]')"
manifest_media_type="$(aws ecr describe-images --repository-name "$repository" \
    --image-ids "imageDigest=$IMAGE_DIGEST" --region "$AWS_REGION" \
    --query 'imageDetails[0].imageManifestMediaType' --output text)"

# --- Wait for the scan of this exact digest (A7) ----------------------------------
findings_file="$(mktemp)"
error_file="$(mktemp)"
trap 'rm -f "$findings_file" "$error_file"' EXIT
echo '{"imageScanStatus":{"status":"PENDING"}}' >"$findings_file"
scan_error=""
case "$manifest_media_type" in
*manifest.list* | *image.index*)
    # ECR does not scan an index; DME publishes a single-platform manifest.
    scan_error="the pushed digest is an image index ($manifest_media_type), not a single $platform manifest"
    ;;
*)
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if aws ecr describe-image-scan-findings --repository-name "$repository" \
            --image-id "imageDigest=$IMAGE_DIGEST" --region "$AWS_REGION" \
            --output json >"$findings_file.new" 2>"$error_file"; then
            mv "$findings_file.new" "$findings_file"
            status="$(jq -r '.imageScanStatus.status // ""' "$findings_file")"
            [ "$status" = "IN_PROGRESS" ] || [ "$status" = "PENDING" ] || [ -z "$status" ] || break
        elif ! grep -q ScanNotFoundException "$error_file"; then
            scan_error="$(head -c 500 "$error_file")"
            break
        fi
        [ "$attempt" -lt "$max_attempts" ] && sleep "$poll_seconds"
    done
    ;;
esac

decision="$(jq -f "$repo_root/scripts/image_scan_decision.jq" "$findings_file")"
if [ -n "$scan_error" ]; then
    decision="$(jq -n --arg reason "Could not evaluate the ECR scan: $scan_error" \
        '{deployment_status: "blocked", scan: {status: "ERROR", severity_counts: {}, blocker_findings: [], reason: $reason}}')"
fi

jq -n \
    --arg source_commit "$GITHUB_SHA" \
    --arg image_tag "${ECR_REPOSITORY_URL}:${image_tag}" \
    --arg publication_purpose "$publication_purpose" \
    --arg image_digest "$IMAGE_DIGEST" \
    --arg image_reference "$image_reference" \
    --arg manifest_media_type "$manifest_media_type" \
    --arg platform "$platform" \
    --arg label_source "$(label source)" \
    --arg label_revision "$(label revision)" \
    --arg label_version "$(label version)" \
    --arg built_at "$built_at" \
    --arg os_release "$os_release" \
    --arg glibc "$glibc" \
    --argjson image_size "$image_size" \
    --argjson runtime "$runtime_json" \
    --argjson base_images "$base_images" \
    --arg run_url "$run_url" \
    --arg run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
    --arg findings_command "aws ecr describe-image-scan-findings --repository-name $repository --image-id imageDigest=$IMAGE_DIGEST --region $AWS_REGION" \
    --argjson decision "$decision" \
    --argjson scan_timestamps "$(jq '{completed_at: (.imageScanFindings.imageScanCompletedAt // null), vulnerability_source_updated_at: (.imageScanFindings.vulnerabilitySourceUpdatedAt // null)}' "$findings_file")" \
    '{
        schema_version: 1,
        workload: "dme-batch",
        publication_status: "published",
        publication_purpose: $publication_purpose,
        deployment_status: $decision.deployment_status,
        source_commit: $source_commit,
        image_tag: $image_tag,
        image_digest: $image_digest,
        image_reference: $image_reference,
        image_manifest_media_type: $manifest_media_type,
        platform: $platform,
        oci_labels: {source: $label_source, revision: $label_revision, version: $label_version},
        base_images: $base_images,
        os_release: $os_release,
        glibc: $glibc,
        image_size_bytes: $image_size,
        runtime: ($runtime + {not_scanned_by_ecr_basic: true}),
        built_at: $built_at,
        workflow_run_url: $run_url,
        workflow_run_attempt: $run_attempt,
        image_contract_verification: {before_push: "passed", after_ecr_pull: "passed"},
        scan: ($decision.scan + $scan_timestamps + {findings_command: $findings_command}),
        exceptions: []
    }' >"$output"

# A1: the OCI revision label of the pushed digest is its source commit.
jq -e '.oci_labels.revision == .source_commit' "$output" >/dev/null ||
    { echo "OCI revision label does not match the source commit" >&2; exit 1; }

deployment_status="$(jq -r .deployment_status "$output")"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## DME batch image publication"
        echo
        echo "- Image: \`$image_reference\`"
        echo "- Tag: \`${ECR_REPOSITORY_URL}:${image_tag}\` (immutable; no \`latest\`)"
        echo "- Purpose: $publication_purpose (comparison images require a separate base-selection decision)"
        echo "- Source commit / OCI revision: \`$GITHUB_SHA\`"
        echo "- Version: \`$(label version)\`; built at \`$built_at\`; $platform"
        echo "- Base: $(jq -r '[.base_images[] | "`\(.reference)` → `\(.resolved_digest)`"] | join(", ")' "$output")"
        echo "- OS: $os_release; runtime: $(jq -r '"Julia \(.runtime.version) (bundled: \(.runtime.bundled_libraries | to_entries | map("\(.key) \(.value)") | join(", ")))"' "$output")"
        echo "- Image contract: passed before push and after pulling the digest from ECR"
        echo "- ECR scan: \`$(jq -r .scan.status "$output")\` $(jq -c .scan.severity_counts "$output")"
        echo "- Deployment status: **$deployment_status** — $(jq -r .scan.reason "$output")"
        if [ "$(jq '.scan.blocker_findings | length' "$output")" -gt 0 ]; then
            echo
            echo "| CVE | Severity | Package | Version |"
            echo "| --- | --- | --- | --- |"
            jq -r '.scan.blocker_findings[] | "| \(.cve) | \(.severity) | \(.package_name) | \(.package_version) |"' "$output"
        fi
    } >>"$GITHUB_STEP_SUMMARY"
fi
echo "Published $image_reference; purpose $publication_purpose; ECR evaluation $deployment_status"
[ "$deployment_status" = "approved" ]
