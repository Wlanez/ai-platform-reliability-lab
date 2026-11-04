#!/usr/bin/env python3
"""Read-only evidence adapters for the SRE investigator.

The model never receives a shell. Every operation here is fixed, bounded,
namespace-scoped, and read-only.
"""
from __future__ import annotations

import json
import os
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

NAMESPACE = os.environ.get("NAMESPACE", "ai-reliability-lab")
PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://127.0.0.1:19091")
LOG_TAIL_LINES = int(os.environ.get("LOG_TAIL_LINES", "80"))

PROMQL = {
    "target_up": 'up{job="incident-demo"}',
    "request_total": 'sum(incident_demo_requests_total{application="incident-demo"})',
    "failure_total": 'sum(incident_demo_failures_total{application="incident-demo"})',
    "mode": 'incident_demo_mode{application="incident-demo"}',
    "http_5xx_total": 'sum(http_server_requests_seconds_count{application="incident-demo",status=~"5.."})',
}

class ToolError(RuntimeError):
    pass

def _run(argv: list[str]) -> str:
    try:
        cp = subprocess.run(argv, check=True, capture_output=True, text=True, timeout=15)
        return cp.stdout
    except subprocess.CalledProcessError as exc:
        raise ToolError(
            f"read-only tool failed: {argv[0]} exit={exc.returncode}: {exc.stderr.strip()}"
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise ToolError(f"read-only tool timed out: {argv[0]}") from exc

def _kubectl_json(args: list[str]) -> Any:
    raw = _run(["kubectl", "-n", NAMESPACE, *args, "-o", "json"])
    return json.loads(raw)

def get_workload_state() -> dict[str, Any]:
    pods = _kubectl_json(["get", "pods", "-l", "app=incident-demo"])
    deployment = _kubectl_json(["get", "deployment", "incident-demo"])
    pod_rows = []
    for item in pods.get("items", []):
        statuses = item.get("status", {}).get("containerStatuses") or []
        pod_rows.append({
            "name": item.get("metadata", {}).get("name"),
            "phase": item.get("status", {}).get("phase"),
            "pod_ip": item.get("status", {}).get("podIP"),
            "ready": bool(statuses) and all(s.get("ready", False) for s in statuses),
            "restart_count": sum(int(s.get("restartCount", 0)) for s in statuses),
            "container_states": [s.get("state", {}) for s in statuses],
        })
    status = deployment.get("status", {})
    return {
        "namespace": NAMESPACE,
        "deployment": {
            "name": "incident-demo",
            "replicas": status.get("replicas", 0),
            "ready_replicas": status.get("readyReplicas", 0),
            "available_replicas": status.get("availableReplicas", 0),
            "unavailable_replicas": status.get("unavailableReplicas", 0),
        },
        "pods": pod_rows,
    }

def get_events() -> list[dict[str, Any]]:
    events = _kubectl_json(["get", "events", "--sort-by=.lastTimestamp"])
    rows = []
    for item in events.get("items", [])[-25:]:
        involved = item.get("involvedObject", {})
        if involved.get("name", "").startswith("incident-demo"):
            rows.append({
                "type": item.get("type"),
                "reason": item.get("reason"),
                "message": item.get("message"),
                "object": f"{involved.get('kind')}/{involved.get('name')}",
                "count": item.get("count"),
                "last_timestamp": item.get("lastTimestamp") or item.get("eventTime"),
            })
    return rows

def get_logs() -> dict[str, Any]:
    text = _run([
        "kubectl", "-n", NAMESPACE, "logs", "deployment/incident-demo",
        "--tail", str(LOG_TAIL_LINES),
    ])
    return {"tail_lines": LOG_TAIL_LINES, "text": text[-12000:]}

def query_prometheus(query_name: str) -> dict[str, Any]:
    if query_name not in PROMQL:
        raise ToolError(f"Prometheus query not allowed: {query_name}")
    query = PROMQL[query_name]
    params = urllib.parse.urlencode({"query": query})
    url = f"{PROMETHEUS_URL}/api/v1/query?{params}"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
    except Exception as exc:
        raise ToolError(f"Prometheus query failed for {query_name}: {exc}") from exc
    if payload.get("status") != "success":
        raise ToolError(f"Prometheus returned non-success for {query_name}")
    values = []
    for result in payload.get("data", {}).get("result", []):
        value = result.get("value", [None, None])
        values.append({
            "metric": result.get("metric", {}),
            "timestamp": value[0],
            "value": value[1],
        })
    return {"name": query_name, "query": query, "values": values}

def collect_evidence() -> dict[str, Any]:
    tool_calls = []
    def observed(tool: str, fn):
        started = datetime.now(timezone.utc)
        try:
            result = fn()
            status = "success"
            error = None
        except Exception as exc:
            result = None
            status = "error"
            error = str(exc)
        finished = datetime.now(timezone.utc)
        tool_calls.append({
            "tool": tool,
            "scope": NAMESPACE if tool.startswith("kubernetes") else "incident-demo",
            "read_only": True,
            "status": status,
            "error": error,
            "started_at": started.isoformat(),
            "finished_at": finished.isoformat(),
        })
        return result

    evidence = {
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "policy": {
            "namespace": NAMESPACE,
            "read_only": True,
            "allowed_kubernetes_operations": [
                "get pods for app=incident-demo",
                "get deployment/incident-demo",
                "get events",
                "logs deployment/incident-demo --tail",
            ],
            "allowed_prometheus_queries": sorted(PROMQL),
            "forbidden": [
                "create", "patch", "update", "delete", "exec", "secrets",
                "arbitrary shell commands", "arbitrary PromQL",
            ],
        },
    }
    evidence["workload"] = observed("kubernetes.workload_state", get_workload_state)
    evidence["events"] = observed("kubernetes.events", get_events)
    evidence["logs"] = observed("kubernetes.logs", get_logs)
    evidence["prometheus"] = {
        name: observed(f"prometheus.{name}", lambda name=name: query_prometheus(name))
        for name in PROMQL
    }
    evidence["tool_calls"] = tool_calls
    return evidence
