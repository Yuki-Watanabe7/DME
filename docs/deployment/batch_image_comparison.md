# Issue #296: Debian 13 / AL2023 batch image comparison

Status: native amd64 publication and comparison measured on 2026-10-04;
AL2023 production-base change is proposed for review. A new production digest
from the merged change is still required. No DME ECS task has been started.

This record supports [DME #296](https://github.com/Yuki-Watanabe7/DME/issues/296)
and [PAP #41](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/41)
under [PAP ADR 0017 §4](https://github.com/Yuki-Watanabe7/personal-analytics-platform/blob/main/docs/adr/0017-production-container-base-image-policy.md).
DME owns the image, CLI and publication evidence; PAP owns ECR, permissions,
storage, runtime configuration and image admission.

## Published native amd64 evidence (2026-10-04)

Both runs used reviewed main commit `d8eba8ad11d0f490815479b7d4085165257bbf66`
([merged preparation PR #301](https://github.com/Yuki-Watanabe7/DME/pull/301)).
PAP created ECR and the main-only OIDC push role, then configured the three
non-secret publication variables from its Terraform handoff. Each run passed
`Pkg.test()`, all ten contract steps before push, and all ten again after pulling
the exact immutable digest from ECR, including the S3-compatible sink and stop
contract. No exception was applied.

| Measurement | Debian production baseline | AL2023 comparison |
| --- | --- | --- |
| Workflow | [37174658453](https://github.com/Yuki-Watanabe7/DME/actions/runs/37174658453) | [37175890840](https://github.com/Yuki-Watanabe7/DME/actions/runs/37175890840) |
| Result | Image published; run failed at vulnerability gate | Image published; run succeeded |
| OS | Debian GNU/Linux 13 (trixie) | Amazon Linux 2023.12.20260930 |
| Julia / glibc | 1.13.1 / 2.41 | 1.13.1 / 2.34 |
| Uncompressed Docker bytes | 2,382,477,078 | 2,390,034,673 |
| All ten steps before push / after ECR pull | Passed / passed | Passed / passed |
| Scan status / completed UTC | COMPLETE / 03:59:58 | COMPLETE / 04:25:00 |
| ECR CRITICAL / HIGH / MEDIUM | 2 / 4 / 2 | 0 / 0 / 0 |
| Publication purpose / scan decision | production / blocked | comparison / approved |
| Exact downloaded A8 evidence | [Debian JSON](evidence/issue296/native-ecr-debian-production.json) | [AL2023 JSON](evidence/issue296/native-ecr-al2023-comparison.json) |

Immutable digests:

- Debian: `sha256:70bd0e26a358c917f2937379c1fbd06b6ae2045e9cf330da7c573e00df4b4bd6`
- AL2023 comparison: `sha256:5c2b389c0b0c0d58c7a85f46eab8f001571d0e15e8db4bab49a303414b6566b5`

The registry is `867965242179.dkr.ecr.ap-northeast-1.amazonaws.com/dme`.
The JSON preserves the exact image/base digests, OCI revision, scan timestamps,
package findings and runtime library versions. These files are unchanged copies
of the downloaded workflow evidence, not reconstructed results.

AL2023 is 7,557,595 bytes (0.32%) larger in uncompressed Docker size. Those bytes
are not billable compressed ECR storage. These original artifacts do not report
compressed registry sizes; the next publication records `ecr_image_size_bytes`
and `ecr_repository_image_bytes_upper_bound` from ECR DescribeImages. The latter
sums compressed image sizes and can count shared layers more than once. It is
conservative storage evidence, not a quota or a precise billed-usage total.

### Debian blocker findings and vendor status

The fresh native build installed four vendor package upgrades and the verifier
found zero pending OS updates. On 2026-10-04 the Debian tracker still marks the
installed trixie versions below as vulnerable, with no fixed trixie package.
An upstream or sid/forky fix is not an available trixie update. ECR severity,
package and version below are preserved; a different vendor severity does not
lower the admission gate.

| CVE / vendor tracker | ECR severity | ECR package | ECR installed version | trixie status (2026-10-04) |
| --- | --- | --- | --- | --- |
| [CVE-2026-8924](https://security-tracker.debian.org/tracker/CVE-2026-8924) | CRITICAL | curl | 8.14.1-2+deb13u5 | Vulnerable; no fixed trixie package |
| [CVE-2026-8927](https://security-tracker.debian.org/tracker/CVE-2026-8927) | CRITICAL | curl | 8.14.1-2+deb13u5 | Vulnerable; no fixed trixie package |
| [CVE-2026-8286](https://security-tracker.debian.org/tracker/CVE-2026-8286) | HIGH | curl | 8.14.1-2+deb13u5 | Vulnerable; no fixed trixie package |
| [CVE-2026-102010](https://security-tracker.debian.org/tracker/CVE-2026-102010) | HIGH | gcc-14 | 14.2.0-19 | Vulnerable; no fixed trixie package |
| [CVE-2026-95619](https://security-tracker.debian.org/tracker/CVE-2026-95619) | HIGH | gcc-14 | 14.2.0-19 | Vulnerable; no fixed trixie package |
| [CVE-2026-85091](https://security-tracker.debian.org/tracker/CVE-2026-85091) | HIGH | zlib | 1.3.dfsg+really1.3.1-1 | Vulnerable; no fixed trixie package (Debian source version has epoch `1:`) |

The historical 2026-09-30 Trivy result used Julia 1.12.6 and another feed. Its
12 HIGH findings are not the canonical current list; this record uses the six
actual ECR blockers above. A finding absent from a different scan is not proof
of a fix in the original digest.

ECR basic scanning does not cover Julia or its bundled JLL libraries. Both
native images record Julia 1.13.1 with LibCURL_jll 8.18.0+1, LibGit2_jll 1.9.1+0,
LibSSH2_jll 1.11.104+0, OpenSSL_jll 3.5.6+0 and Zlib_jll 1.3.1+2. An empty AL2023
OS scan does not establish that these runtime libraries have no vulnerabilities;
upstream Julia security releases remain a separate maintenance obligation.

## Base selection and maintenance

The proposed production choice is AL2023 minimal plus the official Julia 1.13.1
glibc tarball. It removes all six actual OS blockers without exceptions and
passes the same published native runtime contract. This updates ADR 0026
revision 3; deployment still requires a new production publication after merge.

| Axis | Retained Debian baseline | AL2023 production recipe |
| --- | --- | --- |
| Recipe after this change | [`experiments/issue296/Dockerfile.debian`](../../experiments/issue296/Dockerfile.debian) | [`Dockerfile`](../../Dockerfile) |
| Vendor base | `julia:1.13.1-trixie` | `public.ecr.aws/amazonlinux/amazonlinux:2023-minimal` |
| OS updates | `apt-get upgrade` in runtime | `microdnf upgrade` in Julia base and runtime |
| Julia installation | Official Julia image | Official glibc tarball; exact 1.13.1; reviewed SHA-256 per amd64/arm64 |
| Depot | Installed/precompiled on Debian | Installed/precompiled on AL2023; no Debian depot reused |
| Added RPMs | Not applicable | ca-certificates, libatomic, libstdc++, shadow-utils, findutils; extraction tools removed |
| Runtime update ownership | DME updates Julia and Manifests together | Same, plus tarball paths/checksums |
| Complexity | Official Julia image | Explicit tarball validation and minimal RPM maintenance |

The original AL2023 candidate remains under `experiments/issue296/` as the
historical comparison recipe. Future AL2023 production/comparison runs both use
the root Dockerfile so the comparison cannot drift from the proposed production
recipe. The Debian baseline remains independently reproducible.

Checksums come from [Julia's official release checksum list](https://julialang-s3.julialang.org/bin/checksums/julia-1.13.1.sha256).
[AWS's minimal container guide](https://docs.aws.amazon.com/linux/al2023/ug/minimal-container.html)
documents the release-specific tag and microdnf.
[AWS's release cadence](https://docs.aws.amazon.com/linux/al2023/ug/release-cadence.html)
sets AL2023 standard support through 2027-06-30 and security maintenance through
2029-06-30, with support assessed separately for installed packages. From the
2026-10-04 assessment, the 180-day A3 horizon is 2027-04-02, before standard
support ends. Reassess before maintenance begins. Julia's non-LTS support remains
the release-history judgement in ADR 0026 revision 1, not a vendor end-date promise.

## Reproducing the runtime contract

Run both without `--skip-sink`:

```bash
scripts/verify_batch_container.sh --image dme-batch:compare-debian \
  --dockerfile experiments/issue296/Dockerfile.debian --base-os debian13 \
  --platform linux/arm64
scripts/verify_batch_container.sh --image dme-batch:compare-al2023 \
  --platform linux/arm64
```

Step 3 verifies the expected OS, Manifest Julia patch, no pending vendor updates,
glibc and certificate-verified Downloads.jl HTTPS under read-only root with `/tmp`
scratch. Steps 4–10 retain UID/GID 10001, root-owned code/depot, shell/ownership
tools, non-interactive CLI, read-only simulation/quality export, exit codes,
conditional S3 writes, duplicate refusal and SIGTERM/SIGKILL behavior.

`microdnf` lacks `dnf check-update`: the verifier snapshots RPM inventory,
upgrades a disposable container and compares again, failing on any change or
package-manager error. Builds use `--provenance=false --sbom=false` for a
single-platform ECR-scannable manifest. Base provenance is retained in OCI labels
and the publication JSON.

### Historical local ARM64 comparison (2026-10-03)

Both recipes passed all ten steps. [local-arm64.json](evidence/issue296/local-arm64.json)
preserves recipe/verifier/log hashes for working-tree builds (`revision: unknown`).
Debian measured 3,292,713,001 bytes and AL2023 3,303,848,426 uncompressed bytes;
AL2023 was 11,135,425 bytes (0.34%) larger. The stop trials exited 143 and 137,
respectively; neither left a completed manifest or partial final artifact.
These are historical local measurements, not ECR admission evidence. The 137
fallback is permitted, and a single trial does not estimate its frequency.

### Native amd64 PR verification

The [comparison contract workflow](../../.github/workflows/batch-image-contract.yml)
builds both recipes and runs all ten steps on native amd64 without AWS access.
It uploads logs and `image-contract.json` for 30 days. That JSON explicitly says
`publication_status: not_published` and `ecr_scan: not_run`; it does not replace
the production ECR gate. Representative models do not exercise every optional
JLL code path.

## Publication after the reviewed change is merged

Obtain the new reviewed main HEAD, then publish the production recipe:

```bash
gh workflow run publish-batch-image.yml --repo Yuki-Watanabe7/DME --ref main \
  -f source_commit=<reviewed-main-head> -f image_recipe=production-al2023
# Optional same-commit comparisons:
gh workflow run publish-batch-image.yml --repo Yuki-Watanabe7/DME --ref main \
  -f source_commit=<same-reviewed-main-head> -f image_recipe=comparison-debian
gh workflow run publish-batch-image.yml --repo Yuki-Watanabe7/DME --ref main \
  -f source_commit=<same-reviewed-main-head> -f image_recipe=comparison-al2023
```

The push trust remains `repo:Yuki-Watanabe7/DME:ref:refs/heads/main`, without a
GitHub environment or develop trust. Production uses immutable `<commit>`;
comparisons use `<commit>-comparison-<os>`. Repeat dispatch verifies the existing
digest rather than overwriting a tag. A rebuild needs a new source commit.
The recipe selector's regression test checks OS/path/tag/purpose together and
rejects unknown legacy production recipes and invalid commits before writing
workflow variables.

Comparison images consume ECR storage; PAP owns retention. Their scan
`approved` status is evidence for base selection, not permission to deploy them.

## Remaining acceptance and continuing operation

1. Review and merge the AL2023 production recipe/workflow/ADR change together.
2. Publish the new main commit as production; require `Pkg.test()`, all ten steps
   before/after ECR pull and a COMPLETE scan with no HIGH/CRITICAL findings.
3. Hand the new production digest, matching source commit, full A8 evidence and
   support judgement to PAP #41. PAP then reviews admission/runtime settings and
   verifies real ECS execution, retained S3 artifacts and safe reruns.
4. Keep DME #296 open until the production handoff exists, and PAP #41 open until
   its runtime acceptance is complete. The measured comparison does not complete
   either issue.

Record A9 rebuild within 90 days and rescan within 30 days of each production
build/scan. [PAP #159](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/159)
owns rescan automation. New HIGH/CRITICAL findings restart vendor-fix/base
comparison review; no exception is introduced here. Runtime security releases
require Julia, Manifests, workflow pins and tarball checksums to move together.
OS advisories require a fresh-base rebuild and scan on a new source commit.
