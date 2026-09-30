# Decide whether a published DME image digest is admissible under PAP ADR 0017 A7,
# from the output of `aws ecr describe-image-scan-findings` (Issue #252, ADR 0026).
#
#   jq -f scripts/image_scan_decision.jq findings.json
#
# Output: {deployment_status, scan: {status, severity_counts, blocker_findings, reason}}
#   approved  COMPLETE scan with zero HIGH/CRITICAL findings
#   pending   the scan has not completed (IN_PROGRESS / PENDING)
#   blocked   any other scan status, unreadable counts, or a HIGH/CRITICAL finding
#
# A blocked digest can become deployable only through PAP ADR 0017 §4: a rebuild
# when the base release has a fix, a §5 step 2 comparison with another supported
# base, or an approved, expiring exception record per finding. This filter never
# applies an exception; it reports the scanner's findings as they are.

def attribute($key): [(.attributes // [])[] | select(.key == $key) | .value] | first // "unknown";

def blocker_findings:
  [(.imageScanFindings.findings // [])[]
    | select(.severity == "CRITICAL" or .severity == "HIGH")
    | {
        cve: .name,
        severity: .severity,
        package_name: attribute("package_name"),
        package_version: attribute("package_version"),
        uri: (.uri // "")
      }]
  | unique_by([.cve, .package_name, .package_version])
  | sort_by([(if .severity == "CRITICAL" then 0 else 1 end), .cve, .package_name]);

(.imageScanStatus.status // "UNKNOWN") as $status
| (.imageScanFindings.findingSeverityCounts // {}) as $counts
| if ($status == "IN_PROGRESS" or $status == "PENDING") then
    {deployment_status: "pending", scan: {status: $status, severity_counts: {}, blocker_findings: [],
      reason: "The ECR scan has not completed."}}
  elif $status != "COMPLETE" then
    {deployment_status: "blocked", scan: {status: $status, severity_counts: {}, blocker_findings: [],
      reason: "A COMPLETE ECR scan is required (PAP ADR 0017 A7)."}}
  elif ($counts | type) != "object" or ([$counts[] | select((type != "number") or (. < 0))] | length) > 0 then
    {deployment_status: "blocked", scan: {status: $status, severity_counts: {}, blocker_findings: [],
      reason: "The ECR scan severity counts are unreadable."}}
  elif (($counts.CRITICAL // 0) + ($counts.HIGH // 0)) > 0 then
    {deployment_status: "blocked", scan: {status: $status, severity_counts: $counts,
      blocker_findings: blocker_findings,
      reason: "HIGH or CRITICAL findings: rebuild if the base release has a fix, otherwise follow PAP ADR 0017 §4 step 2 (compare another supported base) or record an approved exception per finding (§5)."}}
  else
    {deployment_status: "approved", scan: {status: $status, severity_counts: $counts, blocker_findings: [],
      reason: "COMPLETE ECR scan with no HIGH or CRITICAL findings."}}
  end
