# PAP #41 startup inspection and local reproduction

These records support the package-cache correction in DME PR #303. They are
failure evidence, not successful Fargate acceptance or a scan of a corrected image.

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
AMD64 CI. Subsequent production publication and real PAP execution remain
separate acceptance steps.
