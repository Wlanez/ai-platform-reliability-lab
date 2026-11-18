#!/usr/bin/env python3
"""EXP-002 deterministic gateway for model-selected diagnostic tools."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from tools import get_events, get_logs, get_workload_state, query_prometheus, PROMQL

ALLOWED_TOOLS = {"get_workload_state", "get_events", "get_logs", "query_metric"}
SOURCE_IDS = {
    "get_workload_state": "kubernetes.workload_state",
    "get_events": "kubernetes.events",
    "get_logs": "kubernetes.logs",
}


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


class ToolGateway:
    def __init__(self, audit_path: str, max_calls: int = 8):
        self.audit_path = Path(audit_path)
        self.max_calls = max_calls
        self.calls = 0
        self.audit_path.parent.mkdir(parents=True, exist_ok=True)
        self.audit_path.write_text("", encoding="utf-8")

    def _emit(self, event: dict[str, Any]) -> None:
        with self.audit_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps({"timestamp": now(), **event}) + "\n")

    def execute(self, request_id: str, tool: str, arguments: dict[str, Any]) -> dict[str, Any]:
        self._emit({"event": "tool_request", "request_id": request_id, "tool": tool, "arguments": arguments})

        if self.calls >= self.max_calls:
            return self._deny(request_id, tool, "tool-call budget exhausted")
        if tool not in ALLOWED_TOOLS:
            return self._deny(request_id, tool, "tool is outside deterministic allowlist")

        if tool == "query_metric":
            if set(arguments) != {"name"} or arguments.get("name") not in PROMQL:
                return self._deny(request_id, tool, "metric name is outside fixed Prometheus allowlist")
            source = f"prometheus.{arguments['name']}"
            fn: Callable[[], Any] = lambda: query_prometheus(arguments["name"])
        else:
            if arguments:
                return self._deny(request_id, tool, "tool accepts no arguments")
            source = SOURCE_IDS[tool]
            fn = {
                "get_workload_state": get_workload_state,
                "get_events": get_events,
                "get_logs": get_logs,
            }[tool]

        self.calls += 1
        self._emit({"event": "policy_decision", "request_id": request_id, "decision": "allow", "reason": "EXP-002 diagnostic allowlist"})
        try:
            result = fn()
            self._emit({"event": "execution_result", "request_id": request_id, "executed": True, "status": "success", "source": source})
            return {"ok": True, "source": source, "result": result}
        except Exception as exc:
            self._emit({"event": "execution_result", "request_id": request_id, "executed": True, "status": "error", "source": source, "error": str(exc)})
            return {"ok": False, "source": source, "error": str(exc)}

    def _deny(self, request_id: str, tool: str, reason: str) -> dict[str, Any]:
        self._emit({"event": "policy_decision", "request_id": request_id, "decision": "deny", "reason": reason})
        self._emit({"event": "execution_result", "request_id": request_id, "executed": False, "status": "blocked_before_execution"})
        return {"ok": False, "tool": tool, "error": reason, "denied": True}
