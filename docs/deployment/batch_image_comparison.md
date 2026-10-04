# Issue #296: Debian 13 / AL2023 batch image comparison

Status: all six DME #296 acceptance criteria are satisfied as of 2026-10-05 JST.
The AL2023 base selection (PR #302) and portable-cache correction (PR #303) are
merged. The corrected production image passed publication and OS scanning, and
PAP adopted it and verified real Fargate/S3/rerun acceptance before closing #41.
The original blocked Debian digest and first AL2023 startup failure remain
historical evidence; they are not the accepted production image.

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
compressed registry sizes; the production publication below records `ecr_image_size_bytes`
and `ecr_repository_image_bytes_upper_bound` from ECR DescribeImages. The latter
sums compressed image sizes and can count shared layers more than once. It is
conservative storage evidence, not a quota or a precise billed-usage total.

### AL2023 production publication and PAP startup failure

[PR #302](https://github.com/Yuki-Watanabe7/DME/pull/302) merged at
`2026-10-04T09:53:51Z`, commit `94eadc900f10c420ea415d78ce2f8ecf277a7b2b`.
[Production run 37193760806](https://github.com/Yuki-Watanabe7/DME/actions/runs/37193760806)
published that commit at
`sha256:244b3ecc32ad291585f1de1e417a9e1408f136473de2eea18de5b84487c8dffc`.
The unchanged [production evidence](evidence/issue296/native-ecr-al2023-production.json)
records all ten checks before push and after exact-digest pull, Julia 1.13.1,
AL2023, a COMPLETE scan at `2026-10-04T10:26:21+00:00`, and no findings or
exceptions. ECR reports 710,927,717 compressed image bytes and a 2,131,787,933-byte
repository upper bound at publication time; neither value is a current quota.

PAP adopted this production digest through
[merged PR #171](https://github.com/Yuki-Watanabe7/personal-analytics-platform/pull/171).
Its [first simulation](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37200078980)
stopped with exit 1 before entering DME's CLI. The subsequent
[read-only inspection](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37208693599)
and unchanged [inspection JSON](evidence/pap41/startup-inspection.json) show Julia
attempting to write a cache lock file in the read-only `/opt/julia-depot`.
The preparation container exited 0. At that point successful Fargate completion,
retained S3 bundles and rerun acceptance had not been verified. The corrected
image's later acceptance is recorded below.

This does not change the recorded OS scan decision `deployment_status: approved`:
that field is the publication scan gate, not evidence of successful AWS execution.
[PR #303](https://github.com/Yuki-Watanabe7/DME/pull/303) corrects the package-cache
CPU targets and adds strict-cache execution with generic CPU features within
0.5 vCPU / 2 GiB. It changes the image build and verification; it does not change
PAP resources or start another task. Its subsequent merge, production publication
and PAP adoption completed the required order.

### Corrected production image and completed PAP handoff (2026-10-05 JST)

[PR #303](https://github.com/Yuki-Watanabe7/DME/pull/303) merged at
`2026-10-04T21:04:45Z` (2026-10-05 06:04:45 JST), commit
`b5bb7dfd6a4c6ffcb3235ac9658a1ade7c4026a3`. The
[production publication 37234934566](https://github.com/Yuki-Watanabe7/DME/actions/runs/37234934566)
used exactly that reviewed main commit. Its unchanged
[publication JSON](evidence/issue296/native-ecr-al2023-portable-cache-production.json)
is the final DME handoff record:

| Field | Accepted production value |
| --- | --- |
| Image digest | `sha256:f5c496b0d0086bf40683537d6a7fafb36c7d47f4178c83563ccb8949209e76ef` |
| Source / OCI revision | `b5bb7dfd6a4c6ffcb3235ac9658a1ade7c4026a3` |
| OS / Julia / glibc / platform | AL2023 / 1.13.1 / 2.34 / linux/amd64 |
| Publication purpose / decision | production / approved |
| Tests and all ten steps before push / after exact ECR pull | Passed / passed |
| Generic CPU / strict shipped caches / read-only / 0.5 vCPU / 2 GiB | Both representative commands passed before and after publication |
| Scan / completed UTC / HIGH / CRITICAL / exceptions | COMPLETE / `2026-10-04T21:33:01+00:00` / 0 / 0 / none |
| Docker uncompressed bytes / ECR compressed image bytes | 2,505,732,345 / 737,435,667 |
| Repository compressed image upper bound at publication | 2,869,223,600 bytes |

[PAP PR #173](https://github.com/Yuki-Watanabe7/personal-analytics-platform/pull/173)
merged at `2026-10-04T21:50:13Z`, commit
`54259d26dcdf8319cb829b7b4ae541f7c7fd64a3`, and adopted this exact digest in
`pap-prod-dme-sim:2`. PAP's saved execution evidence records that DME source
commit and digest in every run. The top-level `source_sha` in these PAP records
is the PAP workflow revision; each run's `source_commit` is DME's image source.

| Real AWS verification | Workflow / unchanged saved evidence | Result |
| --- | --- | --- |
| `simulate solow --periods 120` | [37238436818](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37238436818) / [simulation JSON](evidence/pap41/simulation-run.json) | STOPPED, exit 0, logs readable, S3 bundle verified |
| `quality-export` | [37238688592](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37238688592) / [quality JSON](evidence/pap41/quality-run.json) | STOPPED, exit 0, logs readable, S3 bundle verified |
| Isolated manual reruns and reused ID | [37238899758](https://github.com/Yuki-Watanabe7/personal-analytics-platform/actions/runs/37238899758) / [acceptance JSON](evidence/pap41/rerun-acceptance.json) | Two distinct runs exit 0; reused ID exits 4; original bundle unchanged; running tasks 0 |
| Adopted image and continuing-age gates | Same acceptance run / [admission JSON](evidence/pap41/runtime-image-admission.json) | All checks passed; no HIGH/CRITICAL findings or exceptions |

PAP verified S3 manifest identity and artifact size/SHA-256 against the stopped
tasks, including source, image, execution and retained VersionId. See its
[completion record](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/41#issuecomment-5985071464).
PAP #41 closed as completed at `2026-10-04T22:20:16Z` (2026-10-05 07:20:16 JST).
This documentation archive reads existing records; it does not publish another
image, start a task, change IAM or modify canonical S3 data.

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

Compared with the issue's historical Trivy table:

| CVE identity comparison | CVEs |
| --- | --- |
| Present in both | CVE-2026-8286, CVE-2026-8927 |
| Present only in the current ECR blocker list | CVE-2026-8924, CVE-2026-102010, CVE-2026-85091, CVE-2026-95619 |
| Historical Trivy HIGH entries absent from the current ECR blocker list | CVE-2025-69720, CVE-2026-12064, CVE-2026-8458, CVE-2026-16742, CVE-2026-54369, CVE-2026-76642, CVE-2026-78408, CVE-2026-78409, CVE-2026-78410, CVE-2026-9538 |

CVE-2026-8927 was HIGH in historical Trivy and is CRITICAL in current ECR.
This compares identities and recorded severities across different dates,
runtimes, architectures and feeds; absence is not attributed to a package fix.

ECR basic scanning does not cover Julia or its bundled JLL libraries. Both
native images record Julia 1.13.1 with LibCURL_jll 8.18.0+1, LibGit2_jll 1.9.1+0,
LibSSH2_jll 1.11.104+0, OpenSSL_jll 3.5.6+0 and Zlib_jll 1.3.1+2. An empty AL2023
OS scan does not establish that these runtime libraries have no vulnerabilities;
upstream Julia security releases remain a separate maintenance obligation.

## Base selection and maintenance

The production choice merged in PR #302 is AL2023 minimal plus the official Julia 1.13.1
glibc tarball. It removes all six actual OS blockers without exceptions and
passes the same published native runtime contract. This updates ADR 0026
revision 3. The CPU-cache correction in revision 4 is also merged and its new
production publication and PAP runtime acceptance passed as recorded above.

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
the root Dockerfile so the comparison cannot drift from the production
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
tools, non-interactive CLI, read-only simulation/quality export (including
generic CPU features with strict existing-cache loading), exit codes,
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

## DME #296 acceptance and continuing operation

| Issue criterion | Completion evidence |
| --- | --- |
| First COMPLETE ECR scan and actual HIGH/CRITICAL list recorded | Unchanged Debian production JSON records CRITICAL 2 / HIGH 4 and all six CVEs; comparison with historical Trivy identities is above. |
| Available trixie vendor fixes applied by rebuild | The fresh baseline applied vendor upgrades and verified zero pending updates. No fixed trixie package existed for the remaining six blockers at the comparison; the supported alternative was selected instead. The old Debian digest remains blocked. |
| AL2023 measured in the same PAP ECR and all ten steps | Same-source comparison JSON and both workflow records above. |
| Base migrated or valid exceptions supplied | PR #302 migrated the production recipe to AL2023; PR #303 corrected cache portability. Both are merged; no exception was needed. |
| Approved digest handed to PAP #41 | Corrected production JSON matches PAP #173 and all five real task records; PAP #41 completed. |
| ADR and deployment guide updated | ADR 0026 revisions 3/4 and its completion record, this comparison, and the batch container guide retain the decision, evidence and update procedure. |

The implementation and production handoff are complete. The final DME
documentation/archival [PR #304](https://github.com/Yuki-Watanabe7/DME/pull/304)
carries `Closes #296` for closure through the repository's normal PR workflow.
No new image or runtime action is necessary for that documentation change.

Record A9 rebuild within 90 days and rescan within 30 days of each production
build/scan. [PAP #159](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/159)
owns rescan automation. New HIGH/CRITICAL findings restart vendor-fix/base
comparison review; no exception is introduced here. Runtime security releases
require Julia, Manifests, workflow pins and tarball checksums to move together.
OS advisories require a fresh-base rebuild and scan on a new source commit.

The accepted image's [PAP admission record](evidence/pap41/runtime-image-admission.json)
sets rescan due at `2026-11-03T21:33:01Z` (2026-11-04 06:33:01 JST) and rebuild
due at `2027-01-02T21:32:37Z` (2027-01-03 06:32:37 JST). The rebuild age is based
on ECR's push time, not the earlier Docker `built_at` value. These are continuing
operation deadlines, not incomplete initial acceptance. Recheck vendor status
on any future finding/exception review; rebuild when the chosen release has a
fix, otherwise repeat supported-base comparison or obtain per-finding approval.

PAP's 3,000,000,000-byte retained-image operating envelope had 130,776,400 bytes
remaining at publication. It is not an ECR quota and retention is count-based;
any additional image publication needs a fresh capacity check. PAP's runtime
and cost follow-up is [PAP #42](https://github.com/Yuki-Watanabe7/personal-analytics-platform/issues/42).
