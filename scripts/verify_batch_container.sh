#!/usr/bin/env bash
# Verify the DME batch image contract (Issues #220, #252; ADR 0026; PAP ADR 0017).
#
#   scripts/verify_batch_container.sh [--image TAG] [--existing] [--platform PLATFORM]
#                                     [--revision SHA] [--version VERSION] [--skip-sink]
#                                     [--dockerfile PATH] [--base-os debian13|al2023]
#
# Without --existing the image is built from this checkout with the OCI build
# arguments. With --existing the named image is verified as it is, without a
# build: the publish workflow uses this on the image it pulled back from ECR by
# digest. --platform (for example linux/amd64) builds and runs that platform and
# asserts the image architecture. --skip-sink skips step 9, which starts a
# throwaway S3-compatible server (versitygw) to exercise the artifact sink.
#
# Verified, in order:
#   1. build (or use the existing image)
#   2. image configuration: numeric non-root user, exec-form `dme` entrypoint,
#      SIGTERM stop signal, declared artifact volume, OCI source/revision/version
#      labels, architecture, no credentials in the image environment
#   3. expected OS (Debian 13 by default, or AL2023), Julia matching
#      Manifest.toml, and no pending vendor OS updates after a fresh build;
#      glibc and Downloads.jl HTTPS with certificate verification (A3-A5)
#   4. uid/gid 10001; the project and Julia depot are not writable by it; /bin/sh,
#      chown and chmod exist for PAP's volume-prep init container (A6)
#   5. no repository-only content (tests, docs, .git, .env) in the image
#   6. non-interactive: --help succeeds with stdin closed
#   7. read-only root filesystem with only the artifact volume mounted:
#      `simulate solow --periods 120` and `quality-export` complete without any
#      stderr output (no runtime precompilation), and each run
#      manifest records the source commit and image version, matches the artifact
#      bytes, and contains no host or container path
#   8. exit codes: unsupported model -> 2, unwritable artifact volume -> 4
#   9. artifact sink (read-only root, artifact volume and /tmp scratch): the run
#      bundle is published to <prefix>/runs/<run-id>/ with the manifest last, and a
#      reused run id is refused without overwriting
#  10. task stop (SIGTERM, then SIGKILL after 10 seconds as ECS does): exit 143 or
#      137, no run manifest, no partial final artifact
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="dme-batch:verify"
existing=false
platform=""
revision="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
version=""
skip_sink=false
dockerfile="$repo_root/Dockerfile"
base_os=debian13

if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    image="$1" # backward-compatible positional image tag
    shift
fi
while [ $# -gt 0 ]; do
    case "$1" in
    --image) image="$2"; shift 2 ;;
    --existing) existing=true; shift ;;
    --platform) platform="$2"; shift 2 ;;
    --revision) revision="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --skip-sink) skip_sink=true; shift ;;
    --dockerfile) dockerfile="$2"; shift 2 ;;
    --base-os) base_os="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$base_os" in
    debian13|al2023) ;;
    *) echo "unsupported --base-os: $base_os" >&2; exit 2 ;;
esac
[[ "$dockerfile" = /* ]] || dockerfile="$repo_root/$dockerfile"
[ -f "$dockerfile" ] || { echo "missing Dockerfile: $dockerfile" >&2; exit 2; }
manifest_julia="$(sed -n 's/^julia_version = "\(.*\)"$/\1/p' "$repo_root/Manifest.toml")"
if [ "$base_os" = debian13 ]; then
    base_reference="docker.io/library/julia:${manifest_julia}-trixie"
else
    base_reference=public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
fi
if [ -z "$version" ]; then
    project_version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo_root/Project.toml" | head -1)"
    version="${project_version}+${revision:0:12}"
fi

# Pinned so that a sink check never changes behavior between runs.
sink_image="versity/versitygw:v1.8.0"
# Throwaway credentials for the throwaway local server in step 9; not secrets.
sink_access_key="dmeverifyaccess"
sink_secret_key="dmeverifysecretkey"

work_dir="$(mktemp -d)"
suffix="$$-$RANDOM"
network="dme-verify-net-$suffix"
sink_container="dme-verify-s3-$suffix"
term_container="dme-verify-term-$suffix"
cleanup() {
    # -v also removes the anonymous volume of the throwaway S3 server.
    docker rm -f -v "$term_container" "$sink_container" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    # On a Linux host the container's files are owned by UID 10001 and may not be
    # removable by the invoking user; a CI runner is discarded anyway.
    rm -rf "$work_dir" 2>/dev/null || true
}
trap cleanup EXIT

step() { printf '\n=== %s\n' "$1"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi |
        cut -d ' ' -f 1
}
# Docker bind mounts keep host ownership. Let the image's fixed UID (10001) write
# these stand-ins for ECS-provisioned volumes.
new_volume_dir() {
    local dir
    dir="$(mktemp -d "$work_dir/volume.XXXXXX")"
    chmod 0777 "$dir"
    echo "$dir"
}

run_flags=(--rm)
[ -n "$platform" ] && run_flags+=(--platform "$platform")
dme_run() { docker run "${run_flags[@]}" "$@"; }

if [ "$existing" = true ]; then
    step "1. verify existing image $image (expected revision $revision)"
    docker image inspect "$image" >/dev/null
else
    step "1. build $image (revision $revision, version $version${platform:+, $platform})"
    build_flags=(--build-arg "DME_SOURCE_COMMIT=$revision" --build-arg "DME_IMAGE_VERSION=$version")
    if [ -n "$platform" ]; then
        docker pull --platform "$platform" "$base_reference"
    else
        docker pull "$base_reference"
    fi
    # A repeat dispatch must not attribute today's base to an older digest.
    base_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$base_reference")"
    base_digest="${base_digest##*@}"
    build_flags+=(--build-arg "DME_BASE_REFERENCE=$base_reference" --build-arg "DME_BASE_DIGEST=$base_digest")
    [ -n "$platform" ] && build_flags+=(--platform "$platform")
    # Attestations introduce an OCI index even for one platform. The publish
    # contract requires a directly scannable image manifest, not an index.
    docker build --provenance=false --sbom=false "${build_flags[@]}" \
        --file "$dockerfile" --tag "$image" "$repo_root"
fi

step "2. image configuration"
inspect() { docker image inspect --format "$1" "$image"; }
[ "$(inspect '{{.Config.User}}')" = "10001:10001" ] || fail "user is not 10001:10001"
[ "$(inspect '{{json .Config.Entrypoint}}')" = '["dme"]' ] || fail "entrypoint is not exec-form dme"
[ "$(inspect '{{.Config.StopSignal}}')" = "SIGTERM" ] || fail "stop signal is not SIGTERM"
inspect '{{json .Config.Volumes}}' | grep -q '"/var/lib/dme/artifacts"' ||
    fail "artifact volume is not declared"
label() { inspect "{{index .Config.Labels \"org.opencontainers.image.$1\"}}"; }
[ "$(label source)" = "https://github.com/Yuki-Watanabe7/DME" ] || fail "OCI source label"
[ "$(label revision)" = "$revision" ] ||
    fail "OCI revision label is '$(label revision)', expected '$revision'"
[ "$(label version)" = "$version" ] ||
    fail "OCI version label is '$(label version)', expected '$version'"
[ "$(label base.name)" = "$base_reference" ] || fail "OCI base name does not match $base_reference"
[[ "$(label base.digest)" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "missing resolved base digest label"
if [ -n "$platform" ]; then
    [ "$(inspect '{{.Os}}/{{.Architecture}}')" = "$platform" ] ||
        fail "image platform is $(inspect '{{.Os}}/{{.Architecture}}'), expected $platform"
fi
if inspect '{{range .Config.Env}}{{println .}}{{end}}' | grep -Eq '^(AWS_|[A-Z_]*(SECRET|TOKEN|PASSWORD|API_KEY)[A-Z_]*=)'; then
    fail "the image environment contains a credential-like variable"
fi
echo "labels: revision=$(label revision) version=$(label version); platform $(inspect '{{.Os}}/{{.Architecture}}')"

step "3. base OS and runtime"
os_release="$(dme_run --entrypoint /bin/sh "$image" -c '. /etc/os-release; echo "$ID $VERSION_ID ${VERSION_CODENAME:-}"')"
case "$base_os" in
    debian13) [ "$os_release" = "debian 13 trixie" ] || fail "expected Debian 13 (trixie), got '$os_release'" ;;
    al2023) [[ "$os_release" = "amzn 2023 "* ]] || fail "expected Amazon Linux 2023, got '$os_release'" ;;
esac
julia_version="$(dme_run --entrypoint julia "$image" --startup-file=no --version)"
# CI, the Dockerfile and every Manifest.toml pin one Julia patch version (ADR 0026).
[ "$julia_version" = "julia version $manifest_julia" ] ||
    fail "image runtime is '$julia_version', but Manifest.toml was resolved with Julia $manifest_julia"
echo "OS: $os_release; runtime: $julia_version"
if [ "$existing" = false ]; then
    # Both candidates upgrade against their own vendor repositories (A5).
    # microdnf does not implement dnf's check-update. In a disposable container,
    # upgrade and compare the RPM inventories: a change means updates were pending.
    if [ "$base_os" = debian13 ]; then
        upgradable="$(dme_run --user 0 --entrypoint /bin/sh "$image" -c \
            'apt-get update -qq >/dev/null && apt list --upgradable 2>/dev/null | tail -n +2 | wc -l')"
    else
        upgradable="$(dme_run --user 0 --entrypoint /bin/sh "$image" -c \
            'before=$(rpm -qa | sort)
             if ! microdnf upgrade -y >/tmp/dme-verify-upgrade.log 2>&1; then
                 cat /tmp/dme-verify-upgrade.log >&2; exit 1
             fi
             after=$(rpm -qa | sort)
             if [ "$before" = "$after" ]; then echo 0; else echo 1; fi')"
    fi
    [ "$upgradable" -eq 0 ] || fail "$upgradable OS updates are pending after the upgrade step"
    echo "pending OS updates after build: 0"
fi
dme_run --entrypoint /bin/sh "$image" -c 'getconf GNU_LIBC_VERSION'
# A real TLS request exercises the runtime's bundled curl/OpenSSL and the OS CA
# store on both bases. Use read-only root plus the declared /tmp scratch only.
dme_run --read-only --tmpfs /tmp --entrypoint julia "$image" --startup-file=no -e \
    'using Downloads; mktemp() do path, io
         Downloads.download("https://julialang.org/", path; timeout=30)
         @assert filesize(path) > 0
     end; println("Downloads.jl HTTPS with certificate verification: passed")'

step "4. non-root runtime and read-only code"
[ "$(dme_run --entrypoint id "$image" -u)" = "10001" ] || fail "uid is not 10001"
[ "$(dme_run --entrypoint id "$image" -g)" = "10001" ] || fail "gid is not 10001"
dme_run --entrypoint /bin/sh "$image" -c \
    'for path in /opt/dme /opt/dme/src /opt/julia-depot /usr/local/bin/dme; do
         if [ -w "$path" ]; then echo "$path is writable by uid $(id -u)" >&2; exit 1; fi
     done
     test -w /var/lib/dme/artifacts' || fail "runtime write permissions"
dme_run --user 0 --entrypoint /bin/sh "$image" -c 'command -v chown && command -v chmod' >/dev/null ||
    fail "/bin/sh, chown or chmod is missing for the volume-prep init container"

step "5. repository-only content is absent"
dme_run --entrypoint /bin/sh "$image" -c \
    'for path in /opt/dme/test /opt/dme/docs /opt/dme/.git /opt/dme/.env /opt/dme/examples; do
         if [ -e "$path" ]; then echo "$path is in the image" >&2; exit 1; fi
     done
     if find /opt/dme -name ".env*" | grep -q .; then echo ".env file in the image" >&2; exit 1; fi' ||
    fail "image contains repository-only content"

step "6. non-interactive CLI"
dme_run "$image" --help </dev/null >/dev/null || fail "--help failed with stdin closed"
dme_run "$image" simulate solow --help </dev/null >/dev/null || fail "simulate --help failed"

step "7. read-only root filesystem with only the artifact volume"
artifacts="$(new_volume_dir)"
readonly_run=(--read-only --mount "type=bind,src=$artifacts,dst=/var/lib/dme/artifacts")
# A successful run writes nothing to stderr. In particular, "Precompiling" or a
# read-only-filesystem warning would mean the image's package cache is incomplete.
dme_run "${readonly_run[@]}" "$image" simulate solow --periods 120 </dev/null 2>"$work_dir/stderr.log"
dme_run "${readonly_run[@]}" "$image" quality-export </dev/null 2>>"$work_dir/stderr.log"
if [ -s "$work_dir/stderr.log" ]; then
    cat "$work_dir/stderr.log" >&2
    fail "a successful run wrote to stderr"
fi
check_manifest() {
    local manifest="$1" artifact="$2"
    [ -f "$manifest" ] || fail "missing $manifest"
    jq -e --arg version "$version" --arg sha "$(sha256_of "$artifacts/$artifact")" \
        --arg artifact "$artifact" '
        .manifest_schema == "dme-run-manifest/v1" and .status == "succeeded"
        and .exit_code == 0 and .failure == null
        and .image.version == $version and .publication.sink == "filesystem"
        and (.artifacts | length) == 1
        and .artifacts[0].path == $artifact and .artifacts[0].sha256 == $sha' \
        "$manifest" >/dev/null || fail "$manifest does not describe $artifact"
    if [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
        jq -e --arg revision "$revision" \
            '.source.commit == $revision and .source.commit_origin == "environment"' \
            "$manifest" >/dev/null || fail "$manifest does not record source commit $revision"
    fi
    if grep -Eq "/var/lib/dme|$work_dir|/home/|/Users/" "$manifest"; then
        fail "$manifest records a filesystem path"
    fi
}
check_manifest "$artifacts/simulation/solow/run-manifest.json" "simulation/solow/simulation.json"
check_manifest "$artifacts/quality/run-manifest.json" "quality/quality-export.json"
jq -e '.variables.k | length == 120' "$artifacts/simulation/solow/simulation.json" >/dev/null ||
    fail "simulation artifact does not have 120 periods"
if [[ "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    jq -e --arg revision "$revision" '.commit == $revision' \
        "$artifacts/quality/quality-export.json" >/dev/null ||
        fail "quality export does not record source commit $revision"
fi
echo "run bundles: $(jq -r .run_id "$artifacts/simulation/solow/run-manifest.json"), $(jq -r .run_id "$artifacts/quality/run-manifest.json")"

step "8. exit codes"
set +e
dme_run "$image" simulate unsupported </dev/null >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "unsupported model exited $status, expected 2"
readonly_volume="$(new_volume_dir)"
set +e
dme_run --read-only --mount "type=bind,src=$readonly_volume,dst=/var/lib/dme/artifacts,readonly" \
    "$image" simulate solow --periods 4 </dev/null >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 4 ] || fail "unwritable artifact volume exited $status, expected 4"

if [ "$skip_sink" = false ]; then
    step "9. artifact sink (S3-compatible $sink_image)"
    docker network create "$network" >/dev/null
    docker run -d --name "$sink_container" --network "$network" \
        --mount type=volume,dst=/data \
        -e "ROOT_ACCESS_KEY=$sink_access_key" -e "ROOT_SECRET_KEY=$sink_secret_key" \
        "$sink_image" --quiet posix /data >/dev/null
    docker exec "$sink_container" mkdir -p /data/dme-verify
    for ((attempt = 0; attempt < 50; attempt++)); do
        docker exec "$sink_container" nc -z 127.0.0.1 7070 >/dev/null 2>&1 && break
        sleep 0.2
    done
    sink_volume="$(new_volume_dir)"
    run_id="verify-$suffix"
    # HTTP calls (sink, ECS metadata, credentials) need a writable /tmp: Julia's
    # HTTP client writes an SSH known-hosts temp file. On ECS this is a scratch
    # volume at /tmp; here it is a tmpfs.
    sink_run() {
        dme_run --read-only --tmpfs /tmp --network "$network" \
            --mount "type=bind,src=$sink_volume,dst=/var/lib/dme/artifacts" \
            -e AWS_REGION=us-east-1 \
            -e "AWS_ACCESS_KEY_ID=$sink_access_key" -e "AWS_SECRET_ACCESS_KEY=$sink_secret_key" \
            -e DME_ARTIFACT_SINK=s3://dme-verify/acceptance \
            -e "DME_ARTIFACT_SINK_ENDPOINT=http://$sink_container:7070" \
            "$image" simulate solow --periods 120 --run-id "$run_id" </dev/null
    }
    sink_run
    object_root="/data/dme-verify/acceptance/runs/$run_id"
    for path in simulation/solow/simulation.json simulation/solow/run-manifest.json; do
        docker exec "$sink_container" cat "$object_root/$path" >"$work_dir/published.json"
        cmp -s "$work_dir/published.json" "$sink_volume/$path" ||
            fail "published $path differs from the local run bundle"
    done
    jq -e --arg location "s3://dme-verify/acceptance/runs/$run_id/" \
        '.publication == {"sink": "s3", "location": $location} and .run_id_source == "cli"' \
        "$work_dir/published.json" >/dev/null || fail "published manifest publication fields"
    before="$(docker exec "$sink_container" sh -c "find $object_root -type f -exec sha256sum {} + | sort")"
    set +e
    sink_run >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 4 ] || fail "a reused run id exited $status, expected 4"
    after="$(docker exec "$sink_container" sh -c "find $object_root -type f -exec sha256sum {} + | sort")"
    [ "$before" = "$after" ] || fail "a reused run id changed published objects"
    echo "published s3://dme-verify/acceptance/runs/$run_id/ and refused to overwrite it"
fi

step "10. task stop: SIGTERM, then SIGKILL after 10s as ECS does; no run manifest"
# Julia (PID 1) usually exits 143 within a second of SIGTERM. When the signal lands
# while Julia's exit path is blocked (observed during a large artifact write), the
# process keeps waiting until ECS sends SIGKILL after stopTimeout (exit 137). Either
# way the run must leave no manifest and no partial final artifact.
term_volume="$(new_volume_dir)"
term_flags=(-d --name "$term_container" --read-only)
[ -n "$platform" ] && term_flags+=(--platform "$platform")
docker run "${term_flags[@]}" --mount "type=bind,src=$term_volume,dst=/var/lib/dme/artifacts" \
    "$image" simulate solow --periods 5000000 >/dev/null
sleep 3
docker kill --signal TERM "$term_container" >/dev/null
stop_path="SIGTERM"
for ((attempt = 0; attempt < 40; attempt++)); do
    [ "$(docker inspect --format '{{.State.Running}}' "$term_container")" = false ] && break
    sleep 0.25
done
if [ "$(docker inspect --format '{{.State.Running}}' "$term_container")" = true ]; then
    docker kill --signal KILL "$term_container" >/dev/null
    stop_path="SIGKILL after 10s (Julia's SIGTERM exit path blocked)"
fi
status="$(docker wait "$term_container")"
if [ "$status" -eq 0 ]; then
    fail "the run finished before SIGTERM; increase --periods so the signal lands mid-run"
fi
[ "$status" -eq 143 ] || [ "$status" -eq 137 ] || fail "stop exit status is $status, expected 143 or 137"
[ ! -e "$term_volume/simulation/solow/run-manifest.json" ] ||
    fail "a stopped run left a run manifest"
[ ! -e "$term_volume/simulation/solow/simulation.json" ] ||
    jq -e . "$term_volume/simulation/solow/simulation.json" >/dev/null ||
    fail "a stopped run left a partial final artifact"
echo "stopped by $stop_path with exit $status; no manifest and no partial artifact"

printf '\nDME batch container verification passed: %s\n' "$image"
