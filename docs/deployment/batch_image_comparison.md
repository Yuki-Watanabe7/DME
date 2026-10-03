# Issue #296: Debian 13 / AL2023 batch image comparison

Status: comparison preparation; no ECR digest has been published or admitted.
The production Dockerfile continues to use `julia:1.13.1-trixie`.

This record implements the DME side of
[Issue #296](https://github.com/Yuki-Watanabe7/DME/issues/296) and
[PAP ADR 0017 §4](https://github.com/Yuki-Watanabe7/personal-analytics-platform/blob/main/docs/adr/0017-production-container-base-image-policy.md).
The template is
[CentralBankWatcher #66](https://github.com/Yuki-Watanabe7/CentralBankWatcher/issues/66):
committed recipes, the same runtime contract, then scans in PAP's ECR.

## Preconditions checked on 2026-10-03

- [PR #294](https://github.com/Yuki-Watanabe7/DME/pull/294) merged on
  2026-09-30 at 14:38:27 UTC, merge commit
  `2a7464c159bc10434ec9b27aad7a1286801c121c`.
- `gh variable list --repo Yuki-Watanabe7/DME` returned no repository variables.
  `PAP_AWS_REGION`, `PAP_ECR_REPOSITORY_URL` and `PAP_ECR_PUSH_ROLE_ARN` are
  therefore not configured for the publish job.
- `gh run list --repo Yuki-Watanabe7/DME --workflow publish-batch-image.yml`
  returned no runs. There is no initial publication evidence to evaluate.
- [PAP #41](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/41)
  remains open. Creating ECR/IAM resources belongs to that issue, outside #296.
- The earlier Trivy table in #296 measured Julia 1.12.6 on 2026-09-30. This
  comparison uses the current Julia 1.13.1 after #295. Do not treat that historical
  table as an ECR result, or carry its CVEs forward without a new scan.

## Recipes and maintenance

| Axis | Debian baseline | AL2023 evaluation candidate |
| --- | --- | --- |
| Committed recipe | [`Dockerfile`](../../Dockerfile) | [`experiments/issue296/Dockerfile.al2023`](../../experiments/issue296/Dockerfile.al2023) |
| Vendor base | `julia:1.13.1-trixie` | `public.ecr.aws/amazonlinux/amazonlinux:2023-minimal` |
| OS update path | `apt-get upgrade` in runtime | `microdnf upgrade` in both Julia base and runtime |
| Julia installation | Official Julia image | Official glibc tarball, exact 1.13.1, hardcoded SHA-256 for amd64 and arm64 |
| Depot | Installed and precompiled on Debian | Installed and precompiled on AL2023; no Debian depot is reused |
| Additional RPMs | Not applicable | `ca-certificates`, `libatomic`, `libstdc++`, `shadow-utils`, `findutils`; `tar` and `gzip` removed after extraction |
| Runtime update ownership | DME updates Julia patch and Manifests together | Same, plus both tarball checksums and download paths in the candidate recipe |
| Build complexity | Official image plus normal DME build | Explicit tarball download/checksum/extraction and minimal RPM footprint |
| A3 support | Debian/Julia judgement in [ADR 0026](../adr/0026-batch-artifact-retention-and-image-publication.md) | AL2023 standard support to 2027-06-30, security maintenance to 2029-06-30; assess individual installed packages and Julia independently before selecting it |

The tarballs and checksums come from
[Julia's official release checksum list](https://julialang-s3.julialang.org/bin/checksums/julia-1.13.1.sha256).
AL2023's release-specific tag and minimal package manager are documented in
[AWS's minimal container guide](https://docs.aws.amazon.com/linux/al2023/ug/minimal-container.html);
support phases and package-specific support are in
[AWS's release cadence](https://docs.aws.amazon.com/linux/al2023/ug/release-cadence.html).
Reassess A3 before AL2023 enters maintenance; the base's support date does not
establish support for the separately installed Julia runtime.

## Runtime comparison

Run both without `--skip-sink`:

```bash
scripts/verify_batch_container.sh --image dme-batch:compare-debian \
  --platform linux/arm64
scripts/verify_batch_container.sh --image dme-batch:compare-al2023 \
  --dockerfile experiments/issue296/Dockerfile.al2023 --base-os al2023 \
  --platform linux/arm64
```

Step 3 checks the expected vendor OS rather than accepting any distribution.
Both recipes must match `Manifest.toml`'s Julia patch, have no pending vendor
package updates after the build, and complete a certificate-verified Downloads.jl
HTTPS request with read-only root and only `/tmp` scratch. Steps 4–10 retain
UID/GID 10001, root-owned code/depot, `/bin/sh`/`chown`/`chmod`, non-interactive
CLI, read-only simulation/quality export, exit codes, conditional S3 writes,
duplicate refusal and the SIGTERM/SIGKILL contract.

`microdnf` does not provide `dnf check-update`: step 3 snapshots the RPM
inventory, upgrades a disposable container and compares its inventory again.
Any package change fails the fresh-build check; a package-manager failure also
fails rather than reporting zero updates.

Builds explicitly use `--provenance=false --sbom=false` so the result remains
a single-platform manifest that the existing ECR gate can scan directly.
Docker's default provenance attaches an extra manifest through an OCI index
([Docker attestations](https://docs.docker.com/build/metadata/attestations/));
the A8 base provenance remains in the image's OCI labels and publication JSON.

### Local result (2026-10-03, native ARM64)

Both recipes passed all ten steps, without `--skip-sink`. Machine-readable
measurements, recipe/verifier hashes and log hashes are in
[`evidence/issue296/local-arm64.json`](evidence/issue296/local-arm64.json).
These are working-tree builds with revision `unknown`; they do not claim a
published source commit or ECR digest.

| Measurement | Debian 13 | AL2023 |
| --- | --- | --- |
| Julia | 1.13.1 | 1.13.1 |
| glibc | 2.41 | 2.34 |
| Uncompressed image bytes | 3,292,713,001 | 3,303,848,426 |
| Image manifest | Single OCI image manifest | Single OCI image manifest |
| Pending OS updates after build | 0 | 0 |
| Downloads.jl HTTPS / CA verification | Passed | Passed |
| All ten image contract steps | Passed | Passed |
| Stop trial | SIGTERM, exit 143 | SIGKILL after 10 seconds, exit 137 |
| Completed run manifest / partial final artifact after stop | Neither | Neither |
| ECR scan | Not run | Not run |

AL2023 was 11,135,425 bytes (0.34%) larger on this runtime. This is uncompressed
Docker size, not ECR compressed storage. The AL2023 stop trial exercised the
existing permitted 137 fallback; it does not establish how often that fallback
will occur. The DME load/representative simulation/quality export and HTTP sink
exercise the project's dependencies on glibc 2.34; they do not prove every model
and every optional JLL code path. Native amd64 and ECR verification remain
necessary before adopting this base.

### Native amd64 verification

The
[`Batch image comparison contract` workflow](../../.github/workflows/batch-image-contract.yml)
builds both on native amd64 PR runners without AWS authentication, and uploads
the full log plus `image-contract.json` (30 days). Its JSON explicitly says
`publication_status: not_published` and `ecr_scan: not_run`.
The PR's workflow run and its artifacts record the native results; consult them
for the exact tested commit. Neither local ARM64 nor native CI is an ECR scan.

## ECR comparison after PAP #41 supplies the destination

Merge the comparison recipes/workflow into main through review first. Keep the
push role's trust restricted to
`repo:Yuki-Watanabe7/DME:ref:refs/heads/main`; no GitHub environment or develop
trust is required. The existing publish workflow selects one recipe per dispatch
and serializes runs. Obtain the reviewed main HEAD as `source_commit`:

```bash
gh workflow run publish-batch-image.yml --repo Yuki-Watanabe7/DME --ref main \
  -f source_commit=<reviewed-main-head> -f image_recipe=production-debian
gh workflow run publish-batch-image.yml --repo Yuki-Watanabe7/DME --ref main \
  -f source_commit=<same-reviewed-main-head> -f image_recipe=comparison-al2023
# If a same-commit Debian comparison tag is needed separately:
gh workflow run publish-batch-image.yml --repo Yuki-Watanabe7/DME --ref main \
  -f source_commit=<same-reviewed-main-head> -f image_recipe=comparison-debian
```

Each dispatch runs `Pkg.test()`, all ten contract steps before push, and all ten
again on the exact ECR-pulled digest. Both comparison tags are immutable and
separate from `<source commit>`. Repeated dispatches re-evaluate the existing
digest; rebuilding with a fix requires a new commit/tag. Comparison images
consume ECR storage and need a PAP-managed retention policy; DME does not delete
them. A comparison scan with `deployment_status: approved` is evidence for the
decision, not authorization to deploy a comparison tag.

Download each run's `image-publication.json` and preserve the completed scan,
source commit, immutable digest, base digest, OS/Julia/glibc, size, workflow URL
and contract result in this record. The canonical CVE list is
`scan.blocker_findings`; retain scanner severity/package/version unchanged.
Compare it with the historical Trivy table, documenting newly added or absent
CVEs rather than assuming the feeds agree.

For each actual HIGH/CRITICAL finding, check the
[Debian tracker](https://security-tracker.debian.org/tracker/) or
[Amazon Linux advisories](https://alas.aws.amazon.com/alas2023.html), recording
the vendor URL, date and fixed version/status. ECR basic scanning does not cover
Julia or its bundled JLL libraries; keep tracking the versions recorded in
`runtime.bundled_libraries` and the upstream Julia security release path.

## Decision and remaining acceptance criteria

No base migration or exception is approved by this preparation.

1. Publish the first Debian digest and record its `COMPLETE` ECR scan and CVEs.
2. Rebuild on a new commit if trixie offers any fix. Fixable findings do not
   qualify for exceptions.
3. For remaining findings, compare the same-commit AL2023 digest in PAP ECR,
   including all ten steps on the published amd64 digest and image sizes.
4. If AL2023 removes the blockers and is compatible, record the measured choice
   in ADR 0026 (or a new ADR), update the production Dockerfile/workflow and this
   guide through review, then publish a new production digest. Re-run contract
   verification and ECR scan before handing it to PAP #41.
5. Otherwise, draft one exception record per remaining finding using PAP ADR
   0017 §5.1: exact digest/CVE/package/version/severity, vendor status URL,
   category, evidence commands re-runnable on that digest, compensating controls,
   owner, human approver, creation date and expiry. Only a human owner can
   approve it; this workflow does not apply exceptions. CRITICAL expiry is at
   most 30 days, HIGH at most 90, and neither exceeds the digest's A9 rebuild date.
6. Keep #296 open until an admissible production digest and evidence can be
   handed to PAP #41.

## Continuing operation (A9)

Record rebuild and rescan due dates from each production build/scan: rebuild
within 90 days and rescan within 30 days.
[PAP #159](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/159)
owns rescan automation. New HIGH/CRITICAL findings restart the same decision
path. At every exception renewal, recheck the linked vendor tracker and rerun
reachability commands on the exact digest. If a fix is available, rebuild
instead of renewing. A runtime security release requires updating Julia,
Manifests, workflow pins and the candidate's checksums together; an OS advisory
requires a fresh-base rebuild and scan on a new source commit.
