# PAP #41 startup inspection and local reproduction

These records support DME PR #303 and the completed DME #296 / PAP #41 handoff.
Historical failure evidence and corrected-image acceptance are retained separately.

## Completed real-runtime acceptance (2026-10-05 JST)

The following files are unchanged downloads from each workflow's artifact
`phase1b-dme-run-evidence`:

| Saved file | Source workflow |
| --- | --- |
| `simulation-run.json` | [37238436818](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37238436818), `phase-1b/dme/run-evidence.json` |
| `quality-run.json` | [37238688592](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37238688592), `phase-1b/dme/run-evidence.json` |
| `rerun-acceptance.json` | [37238899758](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37238899758), `phase-1b/dme/run-evidence.json` |
| `runtime-image-admission.json` | Same acceptance run, `image-admission-evidence.json` |

The publication JSON for the corrected image is saved under
[`../issue296/native-ecr-al2023-portable-cache-production.json`](../issue296/native-ecr-al2023-portable-cache-production.json),
an unchanged download from DME publication run
[37234934566](https://github.com/Yuki-Watanabe7/DME/actions/runs/37234934566).
The [completion record](../../batch_image_comparison.md) correlates its digest
and DME source with all five task records. `source_sha` is the PAP workflow source;
`runs[].source_commit` is the DME image source. These files record already-completed
acceptance; saving them does not rerun tasks or modify S3 objects.

## Historical startup inspection and local reproduction

- `startup-inspection.json` is an unchanged download from the artifact
  `phase1b-dme-inspection-evidence` of
  [PAP inspection run 37208693599](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37208693599).
  It identifies the stopped AWS task, production digest and DME source commit.
  Its error shows a cache-lock write attempted during `using DME`, before the CLI.
  The AWS log does not identify why Julia rejected the existing cache or the
  CPU features of that Fargate host.
- `local-cpu-cache-rejection.txt` is the unchanged combined stdout/stderr of a
  diagnostic against the existing local ARM64 working-tree image from the
  earlier base comparison. It is not the published AMD64 production digest.
  Its debug log explicitly identifies incompatible CPU features, then the same
  kind of read-only cache-lock failure. The command exited 1:

  ```bash
  docker run --rm --platform linux/arm64 --read-only --tmpfs /tmp \
    --entrypoint julia -e JULIA_DEBUG=loading dme-batch:issue296-al2023 \
    --startup-file=no --cpu-target=generic --project=/opt/dme -e 'using DME'
  ```

The same local image loaded DME with the host's default CPU features. This
establishes a CPU-portability regression to test; the precise reason for AWS's
cache rejection remains an inference. The corrective regression runs both CLI
commands under generic CPU features with strict existing-cache loading on native
AMD64 CI. Subsequent production publication and real PAP execution were separate
acceptance steps and completed with the corrected image recorded above.
