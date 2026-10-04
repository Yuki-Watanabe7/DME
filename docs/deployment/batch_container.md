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
| Base image (PAP ADR 0017 Julia profile, §4 step 2) | `public.ecr.aws/amazonlinux/amazonlinux:2023-minimal` plus the official Julia `1.13.1` glibc tarball, verified with reviewed SHA-256 checksums. Build and runtime inherit the same Julia base. Julia matches CI and every `Manifest.toml`; the verifier rejects a mismatch. See [the measured comparison](batch_image_comparison.md) and ADR 0026 revision 3. |
| OS updates (A5) | Both the Julia base and runtime stage run `microdnf upgrade` against AL2023's own repositories on a freshly pulled base. A rebuild is the fix path for an OS finding. |
| Julia and package reproducibility | The root `Project.toml` plus tracked `Manifest.toml` are copied before `Pkg.instantiate()`. |
| No startup dependency resolution | Packages are installed and precompiled at build time with portable `JULIA_CPU_TARGET=generic` caches; `JULIA_PKG_PRECOMPILE_AUTO=0` at runtime. The verifier requires shipped caches to load on a generic CPU without writing the depot. |
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

## Julia version

Julia `1.13.1` is pinned to the same patch everywhere: the `setup-julia` step of
every workflow, the Dockerfile's download paths and checksums, and the `julia_version` of
`Manifest.toml`, `test/Manifest.toml` and `docs/Manifest.toml`.
The rationale is recorded in
[ADR 0026, revision 1](../adr/0026-batch-artifact-retention-and-image-publication.md#改訂).

- **Exact tarball and checksum.** Julia is not selected through a moving minor
  tag or an unversioned download. A Julia patch update, including fixes to its
  bundled libraries, changes the download paths/checksums, CI, every Manifest
  and the Debian comparison recipe together through review. OS updates still
  come from `microdnf upgrade` on every build (A5).
- **A3 (runtime support of at least 180 days at build time).** Julia publishes no
  end-of-support date for non-LTS releases, so the judgement uses its release
  history: 1.13 is the current stable release (1.13.0 on 2026-09-10, 1.13.1 on
  2026-09-26), no 1.14 pre-release exists, minor releases have come 11–12 months
  apart, and the previous minor kept receiving patches for about four months
  after the next one (1.11.8 and 1.11.9 followed 1.12.0). 1.13 is therefore
  expected to receive patches beyond 2027-03-30, 180 days after 2026-10-01. Judge A3
  again when Julia 1.14.0 is released: from then on, 1.13 is expected to receive
  patches only for a few months, and the next change moves to 1.14.
- **Bundled libraries.** ECR basic scanning does not see Julia or the libraries it
  ships. The publish evidence records their versions per digest; for Julia 1.13.1:

  | Library | Julia 1.12.6 | Julia 1.13.1 |
  |---|---|---|
  | `OpenSSL_jll` | 3.5.4+0 | 3.5.6+0 |
  | `LibCURL_jll` | 8.15.0+0 | 8.18.0+1 |
  | `LibGit2_jll` | 1.9.0+0 | 1.9.1+0 |
  | `LibSSH2_jll` | 1.11.3+1 | 1.11.104+0 |
  | `Zlib_jll` | 1.3.1+2 | 1.3.1+2 |

## Portable package caches

The first real PAP task stopped before entering the CLI: Julia tried to create
`/opt/julia-depot/compiled/v1.13/DME/*.ji.pidfile` on the read-only root filesystem
([PAP failure](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37200078980),
[read-only diagnostic](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37208693599)).
The old image loaded on its build host, but forcing a generic CPU reproduced the
same cache regeneration failure locally. Its build had no portable CPU target;
same-host container verification did not cover CPU differences on Fargate.

Both recipes now set `JULIA_CPU_TARGET=generic` before build-time package loading
and at runtime. Julia documents that this setting controls native code written
to disk caches, while the in-memory JIT can still use the host's CPU features
([Julia environment variables](https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_CPU_TARGET)).
Setting the variable only on an old image does not rebuild its native caches:
publish a new immutable image, then review its admission in PAP.

`JULIA_PKG_PRECOMPILE_AUTO=0` controls automatic package-manager precompilation;
it does not prevent `using DME` from regenerating an unusable cache. Verification
therefore also runs both representative commands with `--cpu-target=generic`
and `--compiled-modules=strict`, which requires existing precompiled files
([Julia command-line switches](https://docs.julialang.org/en/v1/manual/command-line-interface/#Command-line-switches-for-Julia)).
The checks retain read-only root/depot and PAP's 0.5 vCPU / 2 GiB budget.
No additional writable depot, IAM grant or task volume is needed for this fix.
These image checks do not replace real Fargate/S3/rerun acceptance in PAP.

## Writable paths

| Path | Needed by | On ECS |
|---|---|---|
| `/var/lib/dme/artifacts` (or the `--out` / `DME_ARTIFACT_OUTDIR` path) | every command | a task volume at this path, writable by UID 10001 |
| `/tmp` | runs that make HTTP calls: the artifact sink, the ECS task metadata, and the task-role credentials. On the first request of each process, Julia's HTTP client (Downloads.jl / NetworkOptions) writes its bundled SSH known-hosts list to a temp file; without a writable `/tmp` the request fails with `SystemError: mktemp: Read-only file system` (unchanged in Julia 1.13.1). | a scratch task volume at `/tmp` (Fargate has no tmpfs) |

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
handles SIGTERM itself.

- **Julia 1.13.1 (current image).** In 17 timed trials on 2026-10-01 (native
  `linux/arm64`, `simulate solow --periods 5000000`, the signal landing from 0.3
  seconds after start through the computation and the 367 MB artifact write), every
  run exited `143` after SIGTERM: within 0.4–0.8 seconds in 15 trials, and after
  3.5–4.4 seconds in the two signalled late in the artifact write. None needed
  SIGKILL.
- **Julia 1.12.6 (earlier image).** The process usually exited `143` within about a
  second, but when the signal landed while Julia's own exit path was blocked it did
  not exit until SIGKILL (`137`): once in ten trials (during the large artifact
  write) and once in a verification run under heavy CPU load. A signal during the
  first half second of startup ended it with `139`.

Seventeen trials do not rule the blocked exit path out, so treat `137` as a normal
stop. In every case no run manifest is written and a final artifact file is never
partial (artifacts are written to `*.tmp` and renamed), so a stop never corrupts a
run bundle. ECS sends SIGKILL after the task definition's `stopTimeout`; because
nothing needs to finish, a short value such as 10 seconds is safe.

## Build and run locally

```bash
scripts/verify_batch_container.sh --image dme-batch:local --version 0.1.0+local
```

The verifier pulls the vendor base and passes its resolved digest into the OCI
base labels. A direct `docker build` must also pass `DME_BASE_REFERENCE` and
`DME_BASE_DIGEST`; verification and publication require a resolved base digest.

Use `--platform linux/amd64` for the published architecture. Every PAP task
definition declares `X86_64`; do not deploy an image built for the local host
architecture.

On Apple Silicon, Docker Desktop runs `linux/amd64` containers under Rosetta,
where Julia crashes with a segmentation fault in its GC safepoint while it runs
with its default interactive thread (observed with both 1.12.6 and 1.13.1, for
example in `Pkg.instantiate` during the build). With `JULIA_NUM_THREADS=1,0` the
same step succeeds. Build and verify natively there (`--platform linux/arm64`);
the unmodified `linux/amd64` image is verified by the publish workflow on a native
runner before it is pushed.

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
variable is in the image environment; (3) the expected OS (AL2023 by default,
or the Debian baseline with `--base-os debian13`), Julia matching `Manifest.toml`, no pending
vendor update after a fresh build, glibc version, and a certificate-verified
Downloads.jl HTTPS request with read-only root plus `/tmp` scratch; (4) UID/GID 10001, a
read-only project and depot for that user, and `/bin/sh`, `chown` and `chmod` for
PAP's volume-prep init container; (5) no tests, docs, examples, `.git` or `.env`
in the image; (6) `--help` with stdin closed; (7) `simulate solow --periods 120`
and `quality-export` with a read-only root and only the artifact volume, first on
the host CPU and then with a generic CPU target and strict shipped-cache loading,
both within 0.5 vCPU / 2 GiB, with no stderr output (so no runtime precompilation),
and run manifests that match the
artifact bytes, record the source commit and image version, and contain no
filesystem path; (8) exit codes `2` and `4`; (9) the
artifact sink against a throwaway S3-compatible server
(`versity/versitygw:v1.8.0`): publication order, byte-for-byte equality with the
local bundle, and refusal to overwrite on a reused run id; (10) a task stop in
the middle of a run, as ECS performs it (SIGTERM, then SIGKILL after 10 seconds):
exit `143` or `137`, no run manifest, and no partial final artifact.

`--existing` verifies an image without building it (the publish workflow runs it
on the digest pulled back from ECR); `--skip-sink` skips step 9.
`--dockerfile` selects a committed recipe. Both candidates use the same ten
steps; comparison runs never use `--skip-sink`. See the
[Issue #296 comparison record](batch_image_comparison.md) for measurements and
remaining ECR work.

## Publication

[`.github/workflows/publish-batch-image.yml`](../../.github/workflows/publish-batch-image.yml)
publishes to the ECR repository PAP creates in
[PAP #41](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/41):

1. **Trigger**: `workflow_dispatch` on `main`, with `source_commit` equal to the
   main HEAD and `image_recipe` defaulting to `production-al2023`.
   `comparison-debian` and `comparison-al2023` select evaluation recipes and
   publish `<source commit>-comparison-debian` or
   `<source commit>-comparison-al2023`. These tags do not replace the production
   tag or select a production base. `scripts/select_batch_image_recipe.sh` maps
   production/AL2023 comparison to `Dockerfile`, Debian comparison to
   `experiments/issue296/Dockerfile.debian`, and keeps their tag/purpose separate.
   Nothing else publishes; `latest` is never pushed.
2. **Tests**: `Pkg.test()` (tests, Aqua.jl, JuliaFormatter) must pass first.
3. **Build and verify**: pull the base again, build `linux/amd64`, run the
   verification script.
4. **Push**: assume PAP's push role with GitHub OIDC (no stored AWS key), push the
   immutable tag `<source commit>`, and read back the digest. A repeated dispatch
   for the same commit and recipe does not push; it re-verifies the existing digest.
5. **ECR-pulled smoke**: remove the local image, pull `<repository>@<digest>`, and
   run the verification script on it, including the sink and SIGTERM steps.
6. **Scan and evidence**: wait for the `COMPLETE` ECR basic scan of that digest,
   decide with [`scripts/image_scan_decision.jq`](../../scripts/image_scan_decision.jq),
   write `image-publication.json` (uploaded as a 90-day workflow artifact) and the
   workflow summary. The run fails when the digest is not admissible.

`image-publication.json` records the A8 fields: source commit, tag, digest,
image reference, manifest media type, platform, OCI labels, each base reference
with its resolved digest from the image's OCI base labels (also on repeat
dispatch), publication purpose (`production` or `comparison`), OS release,
glibc, uncompressed Docker size (`image_size_bytes`), compressed ECR size
(`ecr_image_size_bytes`) and the conservative repository image-size sum
(`ecr_repository_image_bytes_upper_bound`, shared layers may be counted more than
once), Julia version with the versions of its
bundled OpenSSL, libcurl, libgit2, libssh2 and zlib (which ECR basic scanning
cannot see), build time, workflow run, scan status, completion/feed timestamps
and counts, every HIGH or
CRITICAL finding (CVE, package, version), and the `deployment_status`:

| `deployment_status` | Meaning |
|---|---|
| `approved` | `COMPLETE` scan with no HIGH or CRITICAL finding (A7). For `publication_purpose: comparison`, this is a scan result; a reviewed base-selection decision and production publication are still required. |
| `pending` | The scan did not complete within 10 minutes; re-run the dispatch for the same commit to re-evaluate without pushing. |
| `blocked` | Any other scan status, or a HIGH/CRITICAL finding. Follow PAP ADR 0017 §4: rebuild when the selected vendor release has a fix; otherwise compare another supported base or record an approved, expiring exception per finding (§5). The workflow never applies an exception. |

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

Measured on 2026-09-30 with the Julia 1.12.6 image built from this Dockerfile on
Docker Desktop's Linux ARM64 runtime (8 vCPU, 7.75 GiB). The Julia 1.13.1 image
built on the same runtime on 2026-10-01 is 3.29 GB uncompressed; the other rows
were not re-measured. They are sizing inputs, not guarantees: the published
`linux/amd64` image, Fargate CPU allocation, image pull time and volume latency
differ. PAP #41 should confirm them on the task size it chooses.

| Metric | Measurement |
|---|---|
| `dme simulate solow --periods 120` | 4.9 s wall clock including Julia startup; peak memory 591.8 MiB (container cgroup `memory.peak`) |
| `dme quality-export` | 4.1 s; peak memory 549.5 MiB |
| Image size | 3.34 GB uncompressed; about 0.72 GB gzip-compressed. The Julia depot layer is 1.27 GB uncompressed (artifacts 740 MB, compiled caches 388 MB, of which DME itself 19 MB). |
| Cold start / precompile | The historical local measurement had none at runtime. Packages and DME are precompiled at build time; the current step 7 additionally requires generic-CPU strict-cache loading, after the first Fargate task exposed the same-host verification gap. |

**ECR storage.** Fresh-base builds do not use build cache. The historical
compressed estimate above is not a measurement of the native AL2023 publication.
PAP #41 now owns a 3 GB retained-image operating envelope and lifecycle rules;
this is not an ECR quota. Each publication records compressed registry bytes
separately from Docker size so PAP can check the envelope before runtime adoption.
The repository sum is an upper bound because shared layers can be counted again;
[DME's measured comparison](batch_image_comparison.md) preserves the first native
artifacts without inventing missing compressed sizes.

**Historical preliminary vulnerability picture.** A Trivy 0.74.0 scan of the OS packages of this
image (Debian 13.7, after the upgrade step) on 2026-09-30 reported 12 distinct HIGH
CVEs (no CRITICAL), none with a fixed package in trixie, in `util-linux` and its
libraries, `curl`/`libcurl4t64`, `ncurses`, `systemd` libraries, `libacl1` and
`perl-base`. Trivy and ECR use different feeds, so this is not the admission
result. The actual 2026-10-04 ECR findings and native amd64 comparison are in
[the comparison record](batch_image_comparison.md); the earlier Trivy table is
not used for admission.

## Known limitations

- PAP #41 has created ECR and its push role. The first Debian production image
  had CRITICAL 2 / HIGH 4 and remains blocked in the comparison record. After
  DME #302 merged, [production publication 37193760806](https://github.com/Yuki-Watanabe7/DME/actions/runs/37193760806)
  published the AL2023 image from `94eadc900f10c420ea415d78ce2f8ecf277a7b2b`
  at digest `sha256:244b3ecc32ad291585f1de1e417a9e1408f136473de2eea18de5b84487c8dffc`:
  all ten checks passed before/after ECR pull, and its COMPLETE OS scan had
  CRITICAL 0 / HIGH 0. PAP adopted it, but the first Fargate simulation then
  exposed the CPU-cache issue above. Publish and evaluate a new **production**
  digest after the portable-cache fix is reviewed and merged; the old digest
  and comparison tags are not replacements for that fixed image.
- The S3 sink is verified against the S3-compatible server and SigV4 vectors;
  real S3 retention and ECS identity remain PAP #41's acceptance work.
  The production AL2023 OS admission passed; Fargate completion and retained
  S3/rerun acceptance remain incomplete. The [comparison record](batch_image_comparison.md)
  preserves the earlier measured base comparison without rewriting it.
- Julia patch releases, including fixes to its bundled libraries, are not picked
  up by a rebuild; they need a change that moves CI, the Dockerfile and every
  `Manifest.toml` together. A3 is to be judged again when Julia 1.14.0 is released
  ([Julia version](#julia-version)).
- The `linux/amd64` image has not been verified locally for Julia 1.13.1: Apple
  Silicon runs it under Rosetta, where Julia crashes (see
  [Build and run locally](#build-and-run-locally)). The native `linux/arm64` image
  passed every verification step, and the publish workflow verifies the
  `linux/amd64` image on a native runner before pushing it.
