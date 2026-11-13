#!/usr/bin/env python3
"""Build a consolidated report from already-recorded lab evaluation artifacts."""
from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def load(path: str) -> tuple[dict[str, Any] | None, str | None]:
    p = Path(path)
    if not p.exists():
        return None, "artifact not found"
    try:
        return json.loads(p.read_text(encoding="utf-8")), None
    except (json.JSONDecodeError, OSError) as exc:
        return None, f"artifact unreadable: {exc}"


def normalized_status(data: dict[str, Any] | None, error: str | None) -> str:
    if error or data is None:
        return "NOT_RECORDED"
    raw = data.get("status", data.get("result"))
    return str(raw).upper() if raw else "UNKNOWN"


def entry(identifier: str, name: str, path: str, detail_fn=None) -> dict[str, Any]:
    data, error = load(path)
    row = {
        "id": identifier,
        "name": name,
        "status": normalized_status(data, error),
        "artifact": path,
    }
    if error:
        row["note"] = error
    elif detail_fn:
        row["details"] = detail_fn(data or {})
    return row


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out-json", default="artifacts/report/evaluation-report.json")
    p.add_argument("--out-md", default="artifacts/report/evaluation-report.md")
    a = p.parse_args()

    exp = entry(
        "EXP-001", "HTTP 500 ground-truth scenario",
        "artifacts/experiment-001/http-500-result.json",
        lambda d: {
            "error_rate": (d.get("observed") or {}).get("error_rate"),
            "request_delta": (d.get("observed") or {}).get("request_delta"),
            "failure_delta": (d.get("observed") or {}).get("failure_delta"),
        },
    )
    eval002 = entry(
        "EVAL-002", "Evidence citation contract / agent diagnosis",
        "artifacts/experiment-001/agent-evaluation.json",
        lambda d: {
            "score": d.get("score"),
            "invalid_evidence_ids": d.get("invalid_evidence_ids"),
            "unauthorized_actions_executed": d.get("unauthorized_actions_executed"),
        },
    )
    eval003 = entry(
        "EVAL-003", "Deterministic semantic grounding",
        "artifacts/experiment-001/semantic-grounding-evaluation.json",
        lambda d: {
            "checked_claims": d.get("checked_claims"),
            "supported_claims": d.get("supported_claims"),
            "failed_claims": d.get("failed_claims"),
            "unverified_claims": d.get("unverified_claims"),
            "coverage": d.get("coverage"),
        },
    )
    sec001 = entry(
        "SEC-001", "Kubernetes least-privilege RBAC",
        "artifacts/security/sec-001-evaluation.json",
        lambda d: {"passed_checks": d.get("passed_checks"), "failed_checks": d.get("failed_checks")},
    )
    sec002 = entry(
        "SEC-002", "Restricted ServiceAccount execution identity",
        "artifacts/security/sec-002-evaluation.json",
        lambda d: {"passed_checks": d.get("passed_checks"), "failed_checks": d.get("failed_checks")},
    )
    sec003 = entry(
        "SEC-003", "Adversarial gateway authorization",
        "artifacts/security/sec-003-evaluation.json",
        lambda d: {
            "adversarial_requests": d.get("adversarial_requests"),
            "policy_denials": d.get("policy_denials"),
            "unauthorized_actions_executed": d.get("unauthorized_actions_executed"),
        },
    )
    sec003b = entry(
        "SEC-003B", "Gateway-bypass Kubernetes containment",
        "artifacts/security/sec-003b-evaluation.json",
        lambda d: {
            "requests_forwarded_to_kubernetes": d.get("requests_forwarded_to_kubernetes"),
            "kubernetes_denials": d.get("kubernetes_denials"),
            "unauthorized_actions_executed": d.get("unauthorized_actions_executed"),
            "delete_canary_survived": d.get("delete_canary_survived"),
        },
    )
    sec004 = entry(
        "SEC-004", "Indirect prompt-injection benchmark",
        "artifacts/security/sec-004/summary.json",
        lambda d: {
            "passed": d.get("passed"),
            "total": d.get("total"),
            "pass_rate": d.get("pass_rate"),
            "dangerous_recommendations_detected": sum(
                len(x.get("dangerous_recommendations_detected") or []) for x in d.get("cases") or []
            ),
        },
    )

    reliability = [exp, eval002, eval003]
    security = [sec001, sec002, sec003, sec003b, sec004]
    all_rows = reliability + security
    recorded = [r for r in all_rows if r["status"] not in {"NOT_RECORDED", "UNKNOWN"}]
    missing = [r["id"] for r in all_rows if r["status"] == "NOT_RECORDED"]
    unknown = [r["id"] for r in all_rows if r["status"] == "UNKNOWN"]
    failed = [r["id"] for r in all_rows if r["status"] == "FAIL"]

    if failed:
        overall = "FAIL"
    elif missing or unknown:
        overall = "INCOMPLETE"
    elif all(r["status"] == "PASS" for r in all_rows):
        overall = "PASS"
    else:
        overall = "UNKNOWN"

    report = {
        "report": "AI-SRE-evaluation-report",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "overall_status": overall,
        "summary": {
            "evaluations_expected": len(all_rows),
            "evaluations_recorded": len(recorded),
            "passed": sum(r["status"] == "PASS" for r in all_rows),
            "failed": len(failed),
            "not_recorded": missing,
            "unknown": unknown,
        },
        "reliability": reliability,
        "security": security,
        "interpretation": {
            "PASS": "All expected evaluation artifacts are recorded and report PASS.",
            "INCOMPLETE": "No recorded evaluation failed, but one or more expected artifacts are missing or lack a recognized status.",
            "scope": "This report aggregates recorded experiment outputs; it does not rerun tests or infer results from README text.",
        },
    }

    out_json = Path(a.out_json)
    out_md = Path(a.out_md)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    def detail(row: dict[str, Any]) -> str:
        d = row.get("details") or {}
        if row["id"] == "EVAL-003" and d:
            cov = d.get("coverage")
            return f'{d.get("supported_claims")}/{d.get("checked_claims")} checked supported; coverage={cov:.0%}' if isinstance(cov, (int,float)) else ""
        if row["id"] == "SEC-004" and d:
            return f'{d.get("passed")}/{d.get("total")} attacks passed; dangerous recommendations={d.get("dangerous_recommendations_detected")}'
        if row["id"] == "SEC-003" and d:
            return f'{d.get("policy_denials")} policy denials; unauthorized successes={d.get("unauthorized_actions_executed")}'
        if row["id"] == "SEC-003B" and d:
            return f'{d.get("kubernetes_denials")} Kubernetes denials; unauthorized successes={d.get("unauthorized_actions_executed")}'
        if row["id"] == "EXP-001" and d and isinstance(d.get("error_rate"), (int,float)):
            return f'error rate={d["error_rate"]:.0%}'
        if row["id"] in {"SEC-001","SEC-002"} and d:
            return f'{d.get("passed_checks")} checks passed; {d.get("failed_checks")} failed'
        if row["id"] == "EVAL-002" and d:
            return f'score={d.get("score")}; invalid evidence IDs={len(d.get("invalid_evidence_ids") or [])}'
        return row.get("note", "")

    lines = [
        "# AI SRE Evaluation Report", "",
        f"**Overall status:** {overall}", "",
        f"Generated: {report['generated_at']}", "",
        "This report aggregates recorded artifacts only; it does not rerun experiments or infer results from documentation.", "",
        "## Reliability", "",
        "| Evaluation | Result | Evidence |",
        "| --- | --- | --- |",
    ]
    for row in reliability:
        lines.append(f"| {row['id']} — {row['name']} | **{row['status']}** | {detail(row)} |")
    lines += ["", "## Security", "", "| Evaluation | Result | Evidence |", "| --- | --- | --- |"]
    for row in security:
        lines.append(f"| {row['id']} — {row['name']} | **{row['status']}** | {detail(row)} |")

    lines += ["", "## Interpretation", ""]
    if overall == "PASS":
        lines.append("All expected evaluation artifacts are recorded and report PASS.")
    elif overall == "INCOMPLETE":
        lines.append("No recorded evaluation failed, but the report is incomplete.")
        if missing:
            lines.append("Missing recorded artifacts: " + ", ".join(missing) + ".")
        if unknown:
            lines.append("Artifacts with unknown status: " + ", ".join(unknown) + ".")
    elif overall == "FAIL":
        lines.append("One or more recorded evaluations failed: " + ", ".join(failed) + ".")
    lines += [
        "",
        "EVAL-003 coverage is reported separately from correctness: UNVERIFIED claims are not treated as supported.",
        "SEC-004 measures model-level diagnosis/recommendation resistance; SEC-003 and SEC-003B provide independent execution-containment evidence.",
        "",
    ]
    out_md.write_text("\n".join(lines), encoding="utf-8")

    print(json.dumps(report, indent=2))
    print(f"\nMarkdown: {out_md}")
    print(f"JSON:     {out_json}")
    return 0 if overall == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
