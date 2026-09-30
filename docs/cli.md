# DME CLI and artifact-output contract

`dme` is the stable, non-interactive command boundary for an orchestrator. The
orchestrator selects a DME command and an output directory; it does not invoke a
repository example, provide Julia source code, or need to know Julia expressions.

The launcher is [`bin/dme`](../bin/dme). A package installation or container image
must place this launcher on `PATH` as `dme`; local development may invoke it with
`julia --project=. bin/dme`, but production jobs should invoke the installed
`dme` command directly.

## Commands and exit codes

```text
dme simulate solow [options] --out <dir> [--run-id <id>] [--artifact-sink <uri>]
dme quality-export --out <dir> [--run-id <id>] [--artifact-sink <uri>]
```

The currently supported simulation model is `solow`. It calls the existing public
`SolowModel` and `simulate` APIs; its equations are not reimplemented in the CLI.
`dme quality-export` creates the existing `julia-quality-export/v1` placeholder
using `QualityExport` and `save_quality_export`; it does not run tests.

| Exit code | Meaning | Operator output |
|---:|---|---|
| `0` | Command completed; its artifact and run manifest were saved (and published, when a sink is configured). | Summary, artifact path, run id and manifest path on stdout. |
| `1` | Unexpected CLI failure. | Error summary on stderr. |
| `2` | Invalid command or input, including an invalid `--run-id` or artifact-sink configuration. Nothing is written. | Error summary on stderr. |
| `3` | Model execution failed. A failed run manifest is still written (and published). | Error summary on stderr. |
| `4` | Artifact directory, write, or artifact-sink publication failed, including a reused run id. | Error summary on stderr. |

The CLI never reads stdin or prompts for input. `dme --help` and command-specific
`--help` output are successful (`0`).

## Solow simulation

```bash
dme simulate solow --periods 120 --initial-capital 1.0 --out /var/lib/dme/artifacts
```

Options are `--periods`, `--initial-capital`, `--alpha`, `--savings-rate`,
`--depreciation-rate`, `--population-growth`, and `--technology-growth`. All have
documented defaults in `dme simulate solow --help`. Invalid values are input errors
(`2`).

The command atomically writes:

```text
<out>/simulation/solow/simulation.json
```

The JSON artifact has schema identifier `dme-simulation/v1` and contains:

- `model`: stable model id (`solow`), display name, and effective parameters;
- `run`: `baseline` scenario, requested period count, and initial capital;
- `variables`: the `k`, `y`, `c`, and `inv` time series;
- `generated_at`: UTC generation timestamp.

The destination filename is stable and is atomically replaced on a retry. Immutable
per-run retention is provided by the artifact sink (below), which never overwrites a
published run; alternatively an orchestrator can supply a distinct run-scoped `<out>`.

## Quality export

```bash
dme quality-export --out /var/lib/dme/artifacts
```

This atomically writes:

```text
<out>/quality/quality-export.json
```

It is the existing canonical `julia-quality-export/v1` format. The command only
records the reserved quality tools as `skipped`; use the quality-capture workflow
when measurements are required. Its `commit` is `DME_SOURCE_COMMIT` when set (the
batch image sets it, since the image has no git checkout), else the checkout's HEAD.

## Run bundle: run manifest, run identity and artifact sink

Added by [#252](https://github.com/Yuki-Watanabe7/DME/issues/252) without changing the
paths above. The decision and the rejected alternatives are
[ADR 0026](adr/0026-batch-artifact-retention-and-image-publication.md).

**Run manifest.** After its artifact, each command writes `run-manifest.json` into the
same directory (`<out>/simulation/solow/run-manifest.json`,
`<out>/quality/run-manifest.json`). It is the last file of the run bundle and follows
[`schemas/dme-run-manifest-v1.schema.json`](../schemas/dme-run-manifest-v1.schema.json)
(`dme-run-manifest/v1`):

| Field | Content |
|---|---|
| `run_id`, `run_id_source` | Run identity and where it came from (below). |
| `status`, `exit_code`, `failure` | `succeeded` / `failed`, the CLI exit code, and for a failure only its category (`model_error`, `artifact_io_error`, `unexpected_error`). Error text stays on stderr. |
| `started_at`, `finished_at` | UTC timestamps. |
| `command` | Command name, model, and the effective option values (defaults included). `--out`, `--run-id` and `--artifact-sink` are not recorded. |
| `source` | Repository, source commit (`DME_SOURCE_COMMIT` in the image, else `git rev-parse HEAD`), DME and Julia versions. |
| `image` | `DME_IMAGE_VERSION` and, on ECS, the image digest from the task metadata. |
| `execution` | `local` or `ecs`; on ECS the task ARN, cluster, task definition family/revision, container name, log group and log stream. |
| `publication` | `filesystem`, or `s3` with the run's `s3://…/runs/<run-id>/` location. |
| `artifacts` | Each artifact's path relative to `<out>`, schema, SHA-256 and size. Empty for a failed run. |

The manifest never contains a host path, a credential, or free-text error output.

**Run identity.** The first of these is used: `--run-id <id>`, `DME_RUN_ID`, the ECS task
id (from `ECS_CONTAINER_METADATA_URI_V4`), or a generated
`local-<UTC timestamp>-<suffix>`. An id must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`.

**Artifact sink.** `--artifact-sink s3://<bucket>[/<prefix>]` (or `DME_ARTIFACT_SINK`)
publishes the finished local bundle to `<prefix>/runs/<run-id>/<path relative to out>`:
the artifacts first, then the manifest, each with `If-None-Match: *`, so S3 refuses to
overwrite an existing object. Consequences:

- a run prefix is **published** only when its `run-manifest.json` exists; a prefix
  without one is incomplete (a sink failure or a stopped task) and is not canonical;
- a run id is single-use: reusing one exits `4` and leaves the published run unchanged;
- a failed command (`3`) publishes its failed manifest and keeps its exit code;
- without a sink the behavior is the filesystem contract above.

The sink needs `AWS_REGION` (or `AWS_DEFAULT_REGION`), and credentials from
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`[/`AWS_SESSION_TOKEN`] or, on ECS, the task
role (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`). `DME_ARTIFACT_SINK_ENDPOINT`
(`http(s)://host[:port]`) points it at an S3-compatible server for local verification.
The deployment contract is in [the batch container guide](deployment/batch_container.md).

## Output-directory resolution

For both commands, directory selection follows this precedence:

1. `--out <dir>`
2. `DME_ARTIFACT_OUTDIR`
3. `./artifacts` relative to the process working directory

The default is suitable for standalone use. Deployments should pass `--out` or set
`DME_ARTIFACT_OUTDIR` to a mounted path such as `/var/lib/dme/artifacts`; no CLI
output path is fixed relative to the repository.
