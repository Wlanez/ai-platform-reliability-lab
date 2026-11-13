#!/usr/bin/env python3
"""EVAL-003: deterministic semantic grounding checks for AI SRE evidence claims.

This evaluator intentionally covers only machine-checkable facts in the current
EXP-001 evidence schema. It does not use an LLM as a judge and does not claim
general natural-language entailment.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def prom_value(evidence: dict[str, Any], name: str) -> float | None:
    item = ((evidence.get("prometheus") or {}).get(name) or {})
    values = item.get("values") or []
    try:
        return float(values[0]["value"]) if values else None
    except (KeyError, TypeError, ValueError):
        return None


def numbers(text: str) -> list[float]:
    return [float(x) for x in re.findall(r"(?<![\w.-])-?\d+(?:\.\d+)?", text)]


def mentions_value(text: str, expected: float) -> bool:
    return any(abs(value - expected) < 1e-9 for value in numbers(text))


def evaluate_claim(source: str, observation: str, evidence: dict[str, Any]) -> dict[str, Any]:
    text = observation.lower()
    result: dict[str, Any] = {
        "source": source,
        "observation": observation,
        "status": "UNVERIFIED",
        "reason": "No deterministic semantic rule matched this claim.",
    }

    prom_name = source.removeprefix("prometheus.") if source.startswith("prometheus.") else None
    if prom_name in {"target_up", "request_total", "failure_total", "mode", "http_5xx_total"}:
        actual = prom_value(evidence, prom_name)
        if actual is None:
            result.update(status="FAIL", reason=f"No observed value is available for {source}.")
            return result

        if prom_name == "target_up":
            if re.search(r"\b(down|unreachable|not reachable|scrape fail|scrape failure)\b", text):
                expected_down = actual == 0.0
                result.update(
                    status="PASS" if expected_down else "FAIL",
                    reason=f"Claim says target is down/unreachable; observed target_up={actual:g}.",
                    observed_value=actual,
                )
                return result
            if re.search(r"\b(up|reachable|reachability|scrap(?:e|ing)|scrape target)\b", text):
                expected_up = actual == 1.0
                result.update(
                    status="PASS" if expected_up else "FAIL",
                    reason=f"Reachability claim checked against target_up={actual:g}.",
                    observed_value=actual,
                )
                return result

        if mentions_value(text, actual):
            result.update(
                status="PASS",
                reason=f"Numeric claim matches observed {source}={actual:g}.",
                observed_value=actual,
            )
            return result

        if numbers(text):
            result.update(
                status="FAIL",
                reason=f"Numeric claim does not match observed {source}={actual:g}.",
                observed_value=actual,
            )
            return result

        result.update(
            status="UNVERIFIED",
            reason=f"{source} has observed value {actual:g}, but the claim is not expressed in a machine-checkable form.",
            observed_value=actual,
        )
        return result

    if source == "kubernetes.workload_state":
        workload = evidence.get("workload") or {}
        deployment = workload.get("deployment") or {}
        pods = workload.get("pods") or []
        ready_replicas = int(deployment.get("ready_replicas") or 0)
        available_replicas = int(deployment.get("available_replicas") or 0)
        any_ready = any(bool(p.get("ready")) for p in pods)
        restart_total = sum(int(p.get("restart_count") or 0) for p in pods)

        contradictions = []
        if re.search(r"\b(not ready|unready|no ready)\b", text) and (any_ready or ready_replicas > 0):
            contradictions.append("claim says workload is not ready")
        if re.search(r"\bready\b", text) and not re.search(r"\b(not ready|unready|no ready)\b", text) and not (any_ready or ready_replicas > 0):
            contradictions.append("claim says workload is ready")
        if re.search(r"\b(unavailable|not available)\b", text) and available_replicas > 0:
            contradictions.append("claim says deployment is unavailable")
        if re.search(r"\bavailable\b", text) and not re.search(r"\b(unavailable|not available)\b", text) and available_replicas == 0:
            contradictions.append("claim says deployment is available")
        if re.search(r"\bzero restarts?|0 restarts?\b", text) and restart_total != 0:
            contradictions.append("claim says restart count is zero")

        matched = bool(re.search(r"\bready|unready|available|unavailable|restarts?\b", text))
        if contradictions:
            result.update(
                status="FAIL",
                reason="; ".join(contradictions),
                observed={"ready_replicas": ready_replicas, "available_replicas": available_replicas, "restart_total": restart_total},
            )
        elif matched:
            result.update(
                status="PASS",
                reason="Workload-state claim is consistent with observed readiness/availability/restarts.",
                observed={"ready_replicas": ready_replicas, "available_replicas": available_replicas, "restart_total": restart_total},
            )
        return result

    # Logs/events are intentionally not given broad semantic entailment rules in v1.
    return result


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--diagnosis", required=True)
    p.add_argument("--evidence", required=True)
    p.add_argument("--out", required=True)
    a = p.parse_args()

    diagnosis = json.loads(Path(a.diagnosis).read_text(encoding="utf-8"))
    evidence = json.loads(Path(a.evidence).read_text(encoding="utf-8"))
    catalog = set((evidence.get("evidence_catalog") or {}).keys())

    claims = []
    for item in diagnosis.get("evidence") or []:
        if not isinstance(item, dict):
            continue
        source = str(item.get("source") or "")
        observation = str(item.get("observation") or "")
        if source not in catalog:
            claims.append({
                "source": source,
                "observation": observation,
                "status": "FAIL",
                "reason": "Evidence source is not present in evidence_catalog.",
            })
        else:
            claims.append(evaluate_claim(source, observation, evidence))

    checked = [c for c in claims if c["status"] in {"PASS", "FAIL"}]
    failed = [c for c in claims if c["status"] == "FAIL"]
    unverified = [c for c in claims if c["status"] == "UNVERIFIED"]

    # Cross-source invariant: reachability/readiness must not be presented as proof
    # of successful application requests.
    surface = " ".join(
        str(x)
        for x in [
            (diagnosis.get("diagnosis") or {}).get("summary"),
            diagnosis.get("recommended_next_action"),
            *[i.get("observation") for i in diagnosis.get("evidence") or [] if isinstance(i, dict)],
        ]
        if x
    ).lower()
    invalid_health_inference = bool(re.search(
        r"(up\s*=\s*1|target.{0,30}(up|reachable)|pod.{0,20}ready).{0,80}"
        r"(therefore|proves?|means|confirms?).{0,40}(application|requests?|service).{0,30}(healthy|successful|succeed)",
        surface,
        flags=re.DOTALL,
    ))

    checks = {
        "has_semantically_checkable_claims": bool(checked),
        "all_checked_claims_supported": not failed,
        "no_invalid_readiness_or_reachability_inference": not invalid_health_inference,
    }
    result = {
        "evaluation": "EVAL-003-semantic-grounding",
        "checks": checks,
        "claims": claims,
        "checked_claims": len(checked),
        "supported_claims": sum(c["status"] == "PASS" for c in claims),
        "failed_claims": len(failed),
        "unverified_claims": len(unverified),
        "coverage": round(len(checked) / len(claims), 4) if claims else 0.0,
        "status": "PASS" if all(checks.values()) else "FAIL",
        "scope_note": (
            "Deterministic v1 semantic checks cover Prometheus scalar values, target reachability, "
            "Kubernetes readiness/availability/restarts, and the readiness/reachability != application-success invariant. "
            "Logs/events and unmatched natural-language claims are reported UNVERIFIED, not assumed grounded."
        ),
    }

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
