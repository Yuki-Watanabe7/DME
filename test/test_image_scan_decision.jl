# ECR scan admission decision used by the batch-image publish workflow (Issue #252).
#
# scripts/image_scan_decision.jq turns `aws ecr describe-image-scan-findings` output
# into approved / pending / blocked (PAP ADR 0017 A7). The filter runs under jq, so
# this test needs a jq binary; GitHub's ubuntu runners have one. Without jq the test
# is skipped rather than failing the suite.

using Test
using DME

const _SCAN_DECISION_FILTER =
    normpath(joinpath(@__DIR__, "..", "scripts", "image_scan_decision.jq"))

function _scan_decision(findings_json::AbstractString)
    output = read(
        pipeline(`jq -c -f $(_SCAN_DECISION_FILTER)`; stdin = IOBuffer(findings_json)),
        String,
    )
    return DME._qe_to_plain(DME.json_read(output))
end

@testset "ECR scan admission decision (Issue #252)" begin
    if Sys.which("jq") === nothing
        @test_skip "jq is not installed"
    else
        pending = _scan_decision("""{"imageScanStatus":{"status":"IN_PROGRESS"}}""")
        @test pending["deployment_status"] == "pending"

        for status in ("FAILED", "UNSUPPORTED_IMAGE", "")
            decision = _scan_decision("""{"imageScanStatus":{"status":"$status"}}""")
            @test decision["deployment_status"] == "blocked"
        end
        @test _scan_decision("{}")["deployment_status"] == "blocked"

        # ECR omits zero counts, so an empty map on a COMPLETE scan is clean.
        clean = _scan_decision(
            """{"imageScanStatus":{"status":"COMPLETE"},"imageScanFindings":{"findingSeverityCounts":{"MEDIUM":2,"LOW":1},"findings":[]}}""",
        )
        @test clean["deployment_status"] == "approved"
        @test clean["scan"]["severity_counts"] == Dict("MEDIUM" => 2, "LOW" => 1)

        blocked = _scan_decision("""{
            "imageScanStatus": {"status": "COMPLETE"},
            "imageScanFindings": {
                "findingSeverityCounts": {"HIGH": 2, "CRITICAL": 1, "MEDIUM": 1},
                "findings": [
                    {"name": "CVE-2026-2", "severity": "HIGH", "uri": "https://t/2",
                     "attributes": [{"key": "package_name", "value": "zlib"},
                                    {"key": "package_version", "value": "1:1.3"}]},
                    {"name": "CVE-2026-1", "severity": "CRITICAL",
                     "attributes": [{"key": "package_name", "value": "glibc"},
                                    {"key": "package_version", "value": "2.41-12"}]},
                    {"name": "CVE-2026-2", "severity": "HIGH", "uri": "https://t/2",
                     "attributes": [{"key": "package_name", "value": "zlib"},
                                    {"key": "package_version", "value": "1:1.3"}]},
                    {"name": "CVE-2026-3", "severity": "MEDIUM", "attributes": []},
                    {"name": "CVE-2026-4", "severity": "HIGH"}
                ]
            }
        }""")
        @test blocked["deployment_status"] == "blocked"
        # CRITICAL first; duplicates collapsed; MEDIUM not listed; missing
        # attributes are reported as unknown instead of being dropped.
        @test [f["cve"] for f in blocked["scan"]["blocker_findings"]] ==
              ["CVE-2026-1", "CVE-2026-2", "CVE-2026-4"]
        @test blocked["scan"]["blocker_findings"][1]["package_name"] == "glibc"
        @test blocked["scan"]["blocker_findings"][3]["package_name"] == "unknown"

        unreadable = _scan_decision(
            """{"imageScanStatus":{"status":"COMPLETE"},"imageScanFindings":{"findingSeverityCounts":{"HIGH":"x"}}}""",
        )
        @test unreadable["deployment_status"] == "blocked"
    end
end
