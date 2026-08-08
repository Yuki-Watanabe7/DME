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
dme simulate solow [options] --out <dir>
dme quality-export --out <dir>
```

The currently supported simulation model is `solow`. It calls the existing public
`SolowModel` and `simulate` APIs; its equations are not reimplemented in the CLI.
`dme quality-export` creates the existing `julia-quality-export/v1` placeholder
using `QualityExport` and `save_quality_export`; it does not run tests.

| Exit code | Meaning | Operator output |
|---:|---|---|
| `0` | Command completed and its artifact was saved. | Summary and artifact path on stdout. |
| `1` | Unexpected CLI failure. | Error summary on stderr. |
| `2` | Invalid command or input. | Error summary on stderr. |
| `3` | Model execution failed. | Error summary on stderr. |
| `4` | Artifact directory or write failed. | Error summary on stderr. |

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

The destination filename is stable and is atomically replaced on a retry. An
orchestrator that needs immutable per-run retention should supply a distinct
run-scoped `<out>` directory (for example a mounted volume subdirectory).

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
when measurements are required.

## Output-directory resolution

For both commands, directory selection follows this precedence:

1. `--out <dir>`
2. `DME_ARTIFACT_OUTDIR`
3. `./artifacts` relative to the process working directory

The default is suitable for standalone use. Deployments should pass `--out` or set
`DME_ARTIFACT_OUTDIR` to a mounted path such as `/var/lib/dme/artifacts`; no CLI
output path is fixed relative to the repository.
