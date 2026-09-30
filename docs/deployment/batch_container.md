# ECS RunTask-compatible batch container

The repository-root [`Dockerfile`](../../Dockerfile) packages DME as a
non-interactive compute Job. It deliberately does not run an HTTP server or
embed external-service credentials. Runtime data access should be configured by
the platform and should prefer the approved `economic-data-provider` data path.

This guide is the DME side of the short-lived Job boundary with
personal-analytics-platform (PAP, roadmap PAP #37): DME owns the image recipe, the CLI and exit
codes, the artifact semantics and the publish evidence; PAP owns ECR, the task
definition, IAM, network, logs and the admission of a digest (PAP ADR 0015 and
ADR 0017). The decisions behind this guide are
[ADR 0026](../adr/0026-batch-artifact-retention-and-image-publication.md).

## Image contract

| Concern | Implementation |
|---|---|
| Base image (PAP ADR 0017 Julia profile) | `julia:1.12.6-trixie` in both stages: the official Julia image on Debian 13, with the OS release in the tag (A4). Julia `1.12.6` matches CI and `Manifest.toml`. |
| OS updates (A5) | The runtime stage runs `apt-get update && apt-get upgrade` against trixie's own repositories on the base the build pulled. A rebuild is the fix path for an OS finding. |
| Julia and package reproducibility | The root `Project.toml` plus tracked `Manifest.toml` are copied before `Pkg.instantiate()`. |
| No startup dependency resolution | Packages are installed and precompiled at build time; `JULIA_PKG_PRECOMPILE_AUTO=0` at runtime. The runtime never writes the depot. |
| Process identity | UID/GID `10001` (`dme`), never root. |
| Read-only code | `/opt/dme` (project and source) and `/opt/julia-depot` are owned by root; the runtime user cannot modify them even when the root filesystem is writable. |
| Writable paths | See [Writable paths](#writable-paths): the artifact volume, plus `/tmp` for runs that make HTTP calls. |
| Job command | The exec-form `ENTRYPOINT ["dme"]` runs the stable CLI from [the CLI contract](../cli.md). stdin is never read. |
| Termination and status | `dme` (Julia) is PID 1 with `STOPSIGNAL SIGTERM`, and its exit status is the task exit status. See [Stopping a task](#stopping-a-task). |
| Artifacts and logs | Artifacts use `DME_ARTIFACT_OUTDIR` (default `/var/lib/dme/artifacts`, declared as a `VOLUME`); operator summaries and errors stay on stdout/stderr. |
| Provenance (A1, A8) | OCI labels `org.opencontainers.image.source`, `.revision` (source commit) and `.version` come from the build arguments `DME_SOURCE_COMMIT` and `DME_IMAGE_VERSION`, which the image also exports as environment variables for the run manifest. |
| Platform (A2) | Published for `linux/amd64`. |

No source bind mount is required. The final image contains only the project
source, the resolved Julia depot and the `dme` launcher; `.dockerignore` keeps
tests, docs, examples, `.git` and credentials out of the build context.

## Writable paths

| Path | Needed by | On ECS |
|---|---|---|
| `/var/lib/dme/artifacts` (or the `--out` / `DME_ARTIFACT_OUTDIR` path) | every command | a task volume at this path, writable by UID 10001 |
| `/tmp` | runs that make HTTP calls: the artifact sink, the ECS task metadata, and the task-role credentials. Julia's HTTP client (Downloads.jl / NetworkOptions) writes a small SSH known-hosts temp file on every request. | a scratch task volume at `/tmp` (Fargate has no tmpfs) |

Nothing else is written. A filesystem-only run (no sink, outside ECS) works with
`readonlyRootFilesystem` and only the artifact volume; on ECS always provide both,
otherwise the metadata read fails with a `dme: warning:` line and the sink fails
with exit code `4`.

## Run bundle and artifact retention

Fargate's ephemeral storage disappears with the task, so a Job run publishes its
artifacts to S3. The full CLI behavior is in
[the CLI contract](../cli.md#run-bundle-run-manifest-run-identity-and-artifact-sink);
in short:

1. The command writes its artifact under `--out` (atomic rename), then
   `run-manifest.json` next to it
   ([`dme-run-manifest/v1`](../../schemas/dme-run-manifest-v1.schema.json)).
2. With `DME_ARTIFACT_SINK=s3://<bucket>/<prefix>`, the bundle is copied to
   `s3://<bucket>/<prefix>/runs/<run-id>/<same relative paths>`, artifacts first
   and the manifest last, each `PUT` with `If-None-Match: *`.
3. On ECS the run id is the task id, so the S3 prefix, the task ARN and the log
   stream (`<prefix>/<container>/<task-id>`) share one identifier; the manifest
   also records the task ARN, the task definition revision, the image digest and
   the source commit.

| Situation | Exit code | What the sink holds |
|---|---:|---|
| success | `0` | artifacts + manifest (`status: succeeded`): **published** |
| model failure | `3` | a failed manifest (failure category only, no artifacts) |
| invalid input | `2` | nothing (the run never started) |
| sink failure after a successful command | `4` | objects without a manifest: **incomplete**, not canonical |
| run id reused (static `DME_RUN_ID`, delivery retry with `--run-id`) | `4` | the earlier run, unchanged (`412 Precondition Failed`) |
| task stopped (SIGTERM, or SIGKILL after `stopTimeout`) | `143` / `137` | no manifest: incomplete |
| manual rerun or overlapping scheduled task | per run | a separate `runs/<task-id>/` prefix per task |

A consumer lists `runs/`, reads each `run-manifest.json`, and uses only runs whose
manifest exists and says `succeeded`; `artifacts[].sha256` verifies each object.
There is no mutable "latest" object.

## Stopping a task

DME has no graceful-shutdown work: a stopped run is simply incomplete. Julia
handles SIGTERM itself. In trials on this image it exited `143` within about a
second in most cases. When the signal landed while Julia's own exit path was
blocked, the process did not exit until SIGKILL (`137`): this was seen once in ten
timed trials (during the large artifact write of a 5-million-period run) and once
in a verification run under heavy CPU load. A signal during Julia's first
half second of startup ended it with `139`. In every case no run manifest is
written and a final artifact file is never partial (artifacts are written to
`*.tmp` and renamed), so a stop never corrupts a run bundle. ECS sends SIGKILL
after the task definition's `stopTimeout`; because nothing needs to finish, a short
value such as 10 seconds is safe.

## Build and run locally

```bash
docker build \
  --build-arg DME_SOURCE_COMMIT="$(git rev-parse HEAD)" \
  --build-arg DME_IMAGE_VERSION="0.1.0+local" \
  --tag dme-batch:local .
```

Use `--platform linux/amd64` for the published architecture. Every PAP task
definition declares `X86_64`; do not deploy an image built for the local host
architecture.

```bash
mkdir -p ./artifacts-from-container
chmod 0777 ./artifacts-from-container  # local Docker only; on ECS the volume maps to UID 10001
docker run --rm --read-only \
  --mount type=bind,src="$PWD/artifacts-from-container",dst=/var/lib/dme/artifacts \
  dme-batch:local simulate solow --periods 120
```

This writes `simulation/solow/simulation.json` and
`simulation/solow/run-manifest.json` under `./artifacts-from-container`.

## Verification

```bash
scripts/verify_batch_container.sh                      # build this checkout and verify
scripts/verify_batch_container.sh --platform linux/amd64
scripts/verify_batch_container.sh --image <ref> --existing --revision <sha> --version <v>
```

The script needs Docker and `jq`. It checks, in order: (1) the build or the named
image; (2) the numeric non-root user, exec-form entrypoint, SIGTERM stop signal,
declared artifact volume, OCI labels, architecture, and that no credential-like
variable is in the image environment; (3) Debian 13 and the Julia version, and
after a fresh build that trixie has no pending update; (4) UID/GID 10001, a
read-only project and depot for that user, and `/bin/sh`, `chown` and `chmod` for
PAP's volume-prep init container; (5) no tests, docs, examples, `.git` or `.env`
in the image; (6) `--help` with stdin closed; (7) `simulate solow --periods 120`
and `quality-export` with a read-only root and only the artifact volume, with no
stderr output (so no runtime precompilation), and run manifests that match the
artifact bytes, record the source commit and image version, and contain no
filesystem path; (8) exit codes `2` and `4`; (9) the
artifact sink against a throwaway S3-compatible server
(`versity/versitygw:v1.8.0`): publication order, byte-for-byte equality with the
local bundle, and refusal to overwrite on a reused run id; (10) a task stop in
the middle of a run, as ECS performs it (SIGTERM, then SIGKILL after 10 seconds):
exit `143` or `137`, no run manifest, and no partial final artifact.

`--existing` verifies an image without building it (the publish workflow runs it
on the digest pulled back from ECR); `--skip-sink` skips step 9.

## Publication

[`.github/workflows/publish-batch-image.yml`](../../.github/workflows/publish-batch-image.yml)
publishes to the ECR repository PAP creates in
[PAP #41](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/41):

1. **Trigger**: `workflow_dispatch` on `main`, with `source_commit` equal to the
   main HEAD. Nothing else publishes; `latest` is never pushed.
2. **Tests**: `Pkg.test()` (tests, Aqua.jl, JuliaFormatter) must pass first.
3. **Build and verify**: pull the base again, build `linux/amd64`, run the
   verification script.
4. **Push**: assume PAP's push role with GitHub OIDC (no stored AWS key), push the
   immutable tag `<source commit>`, and read back the digest. A repeated dispatch
   for the same commit does not push; it re-verifies the existing digest.
5. **ECR-pulled smoke**: remove the local image, pull `<repository>@<digest>`, and
   run the verification script on it, including the sink and SIGTERM steps.
6. **Scan and evidence**: wait for the `COMPLETE` ECR basic scan of that digest,
   decide with [`scripts/image_scan_decision.jq`](../../scripts/image_scan_decision.jq),
   write `image-publication.json` (uploaded as a 90-day workflow artifact) and the
   workflow summary. The run fails when the digest is not admissible.

`image-publication.json` records the A8 fields: source commit, tag, digest,
image reference, manifest media type, platform, OCI labels, each base reference
with its resolved digest, OS release, Julia version with the versions of its
bundled OpenSSL, libcurl, libgit2, libssh2 and zlib (which ECR basic scanning
cannot see), build time, workflow run, scan status and counts, every HIGH or
CRITICAL finding (CVE, package, version), and the `deployment_status`:

| `deployment_status` | Meaning |
|---|---|
| `approved` | `COMPLETE` scan with no HIGH or CRITICAL finding (A7). |
| `pending` | The scan did not complete within 10 minutes; re-run the dispatch for the same commit to re-evaluate without pushing. |
| `blocked` | Any other scan status, or a HIGH/CRITICAL finding. Follow PAP ADR 0017 §4: rebuild if trixie has a fix; otherwise compare AL2023 minimal plus the official Julia tarball (§4 step 2), or record an approved, expiring exception per finding (§5). The workflow never applies an exception. |

### Repository variables and the OIDC subject

| Variable | Value |
|---|---|
| `PAP_AWS_REGION` | the ECR region, e.g. `ap-northeast-1` |
| `PAP_ECR_REPOSITORY_URL` | `<account>.dkr.ecr.<region>.amazonaws.com/<repository>` |
| `PAP_ECR_PUSH_ROLE_ARN` | `arn:aws:iam::<account>:role/<push role>` |

The workflow checks that the repository URL and role ARN name the same account
and region. DME's OIDC subject configuration is the default (`use_default: true`),
so the publish job's subject is **`repo:Yuki-Watanabe7/DME:ref:refs/heads/main`**.
The job deliberately has no GitHub `environment`, which would change the subject
to `repo:Yuki-Watanabe7/DME:environment:<name>`.

## Handoff to PAP #41

What the DME Job needs from PAP, derived from the contract above. PAP decides
names, retention periods and placement.

| PAP resource | Requirement from DME |
|---|---|
| ECR repository | immutable tags, scan on push; a lifecycle exemption for the pinned source-commit tag (ADR 0017 A1) |
| ECR push role | trust `repo:Yuki-Watanabe7/DME:ref:refs/heads/main` (audience `sts.amazonaws.com`); `ecr:GetAuthorizationToken` on `*`; on the repository: `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage` (push), `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` (pull-back smoke), `ecr:DescribeImages`, `ecr:DescribeImageScanFindings` (digest and scan evidence) |
| S3 artifact sink | a bucket and prefix, handed to the task as `DME_ARTIFACT_SINK=s3://<bucket>/<prefix>`; a lifecycle rule on `<prefix>/runs/` if runs expire. The bucket is canonical data and outlives compute teardown. |
| Task role | `s3:PutObject` on `arn:aws:s3:::<bucket>/<prefix>/runs/*` only. DME never reads, lists or deletes. |
| Task definition | image by digest; `user` `10001:10001`; `readonlyRootFilesystem: true`; volumes at `/var/lib/dme/artifacts` and `/tmp` writable by UID 10001; environment `DME_ARTIFACT_SINK` and `AWS_REGION`; command, for example `["simulate", "solow", "--periods", "120"]` or `["quality-export"]` (the entrypoint is `dme`, and `--out` defaults to the artifact volume); a short `stopTimeout` such as 10 seconds ([Stopping a task](#stopping-a-task)); no secrets (neither command needs one) |
| Acceptance | per run: `aws s3api get-object` of `<prefix>/runs/<task-id>/…/run-manifest.json`; check `status`, `artifacts[].sha256`, and that `execution.ecs.task_arn`, `image.digest` and `source.commit` match `describe-tasks` and the image tag |

The stable CLI exit codes keep their meaning (`0` success, `2` input, `3` model,
`4` artifact or sink, `1` unexpected; `143`/`137` stopped); PAP maps them for
reporting only.

## Representative resource profile

Measured on 2026-09-30 with the image built from this Dockerfile on Docker
Desktop's Linux ARM64 runtime (8 vCPU, 7.75 GiB). They are sizing inputs, not
guarantees: the published `linux/amd64` image, Fargate CPU allocation, image pull
time and volume latency differ. PAP #41 should confirm them on the task size it
chooses.

| Metric | Measurement |
|---|---|
| `dme simulate solow --periods 120` | 4.9 s wall clock including Julia startup; peak memory 591.8 MiB (container cgroup `memory.peak`) |
| `dme quality-export` | 4.1 s; peak memory 549.5 MiB |
| Image size | 3.34 GB uncompressed; about 0.72 GB gzip-compressed. The Julia depot layer is 1.27 GB uncompressed (artifacts 740 MB, compiled caches 388 MB, of which DME itself 19 MB). |
| Cold start / precompile | none at runtime: packages and DME are precompiled at build time, and step 7 of the verification fails on any runtime precompile output |

**ECR storage.** Publish builds deliberately use no build cache, so the
`apt-get upgrade` layer is always rebuilt on a fresh base (A5). Their depot layer
therefore differs from the previous image's, and each published image adds about
0.7 GB compressed to the repository. This is above the ≤ 0.5 GB ECR line in PAP's
Job cost envelope for DME (PAP ADR 0015 §7): at USD 0.10/GB-month it is about USD 0.07/month per
retained image, so PAP #41 should size the lifecycle rule (and the envelope) by the
number of DME images it keeps.

**Preliminary vulnerability picture.** A Trivy 0.74.0 scan of the OS packages of this
image (Debian 13.7, after the upgrade step) on 2026-09-30 reported 12 distinct HIGH
CVEs (no CRITICAL), none with a fixed package in trixie, in `util-linux` and its
libraries, `curl`/`libcurl4t64`, `ncurses`, `systemd` libraries, `libacl1` and
`perl-base`. Trivy and ECR use different feeds, so this is not the admission
result; it indicates that the first ECR scan is likely to be `blocked` and to need
PAP ADR 0017 §4 step 2 (AL2023 minimal plus the official Julia tarball, measured in
PAP's ECR) or §5 exception records.

## Known limitations

- The first publication has not run yet: it needs the ECR repository and push
  role from PAP #41. Until then the S3 path is verified only against the
  S3-compatible server in step 9 and the SigV4 test vectors.
- Debian 13 is likely to carry HIGH/CRITICAL findings that Debian has not fixed.
  If the first ECR scan reports them, the digest is `blocked` until the PAP ADR
  0017 §4 step 2 comparison or §5 exception records are done.
- Julia `1.12.6` is pinned. `1.12.7` and the `1.13` series exist; moving Julia is a
  separate change aligned with CI and every `Manifest.toml`, and PAP ADR 0017 A3
  (runtime support window) must be judged for the version in use.
