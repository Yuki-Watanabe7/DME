# ECS RunTask-compatible batch container

The repository-root [`Dockerfile`](../../Dockerfile) packages DME as a
non-interactive compute Job. It deliberately does not run an HTTP server or
embed external-service credentials. Runtime data access should be configured by
the platform and should prefer the approved `economic-data-provider` data path.

## Image contract

The image uses the following controls:

| Concern | Implementation |
|---|---|
| Julia and package reproducibility | Julia `1.12.6` and the root `Project.toml` plus tracked `Manifest.toml` are copied before installation. |
| No startup dependency resolution | `Pkg.instantiate()` occurs during build; `JULIA_PKG_PRECOMPILE_AUTO=0` is set at runtime. |
| Cold-start mitigation | A four-period `dme simulate solow` warm-up runs at build time, using the same `/opt/dme` project path and `/opt/julia-depot` depot path that runtime uses. It writes Julia's package cache for the CLI's representative execution path and is limited to two workers to keep the build within modest Docker Desktop/CI memory limits. |
| Process identity | The runtime uses UID/GID `10001` (`dme`), never root. |
| Job command | The exec-form `ENTRYPOINT ["dme"]` runs the stable CLI from [the CLI contract](../cli.md). |
| Termination and status | `dme` is PID 1 with `STOPSIGNAL SIGTERM`; its exit status is the container/task exit status. |
| Artifacts and logs | Artifacts use `DME_ARTIFACT_OUTDIR` (default `/var/lib/dme/artifacts`); operator summaries and errors remain on stdout/stderr. |

No source bind mount is required. The final runtime stage contains only the
project source, resolved Julia depot, and launcher needed by `dme`.

## Build and run

Build from the repository root:

```bash
docker build --tag dme-batch:local .
```

Build for the Linux CPU architecture declared by the ECS task definition. For
example, use `--platform linux/amd64` for an x86_64 Fargate task or
`--platform linux/arm64` for an ARM64 task; do not build an image for the local
host architecture and deploy it to a mismatched task architecture.

Run the representative Solow simulation with an artifact directory supplied by
the runtime:

```bash
mkdir -p ./artifacts-from-container
chmod 0777 ./artifacts-from-container  # local Docker example; ECS volume permissions should map to UID 10001
docker run --rm \
  --mount type=bind,src="$PWD/artifacts-from-container",dst=/var/lib/dme/artifacts \
  dme-batch:local simulate solow --periods 100
```

The artifact is written to
`./artifacts-from-container/simulation/solow/simulation.json`. To use another
mounted location, pass `--out <path>` or set `DME_ARTIFACT_OUTDIR`; the CLI
preference order is documented in [the CLI contract](../cli.md).

The container only works with paths writable by UID/GID `10001`. ECS task
definitions should therefore mount an ephemeral/EFS volume with that ownership
or compatible permissions. Do not inject cloud or external API credentials into
the image.

Run the complete container acceptance check:

```bash
scripts/verify_batch_container.sh
```

It builds the image, confirms its non-root and exec-form configuration, runs the
100-period simulation without a source mount, verifies the artifact, and checks
that an invalid model preserves the CLI's exit code `2`.

## Representative resource profile

The following measurements were taken on 2026-08-09 with Docker Desktop's Linux
ARM64 runtime (8 vCPU, 7.75 GiB memory). They are indicative deployment-sizing
inputs, not throughput guarantees; Fargate CPU allocation, image pull time, and
mounted-volume latency affect the result.

| Metric | Measurement |
|---|---|
| Scenario | `dme simulate solow --periods 100` |
| Image size | 705,690,854 bytes (673.0 MiB). |
| Cold start / precompile impact | First local `docker run`: 3.10 s; second run: 3.06 s (0.04 s difference). Image pull and ECS task provisioning are excluded. |
| Peak memory | 436,879,360 bytes (416.6 MiB), from the container cgroup's `memory.peak` after the run. |
| Wall-clock duration | 3.10 s for the first local container run. |

For initial Fargate task-definition sizing, use the measured peak with headroom
and validate it under the actual task CPU/memory setting before enabling a
production schedule.
