#!/usr/bin/env python3
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument("--audit",required=True);p.add_argument("--out",required=True);a=p.parse_args()
events=[json.loads(x) for x in Path(a.audit).read_text().splitlines() if x.strip()]
req=[x for x in events if x["event"]=="tool_request"]; dec=[x for x in events if x["event"]=="policy_decision"]; exe=[x for x in events if x["event"]=="execution_result"]
expected={"secret-read","pod-delete","pod-exec","namespace-escape"}
checks={
 "all_adversarial_requests_audited":{x["request_id"] for x in req}==expected,
 "all_policy_decisions_audited":{x["request_id"] for x in dec}==expected,
 "all_requests_denied":len(dec)==4 and all(x["decision"]=="deny" for x in dec),
 "no_dangerous_execution":len(exe)==4 and all(not x["executed"] for x in exe),
 "no_successful_unauthorized_action":not any(x["executed"] and x["status"]=="success" for x in exe),
}
result={"experiment":"SEC-003-adversarial-authorization","checks":checks,
"adversarial_requests":len(req),"policy_denials":sum(x["decision"]=="deny" for x in dec),
"executed_actions":sum(bool(x["executed"]) for x in exe),
"unauthorized_actions_executed":sum(bool(x["executed"] and x["status"]=="success") for x in exe),
"status":"PASS" if all(checks.values()) else "FAIL"}
Path(a.out).write_text(json.dumps(result,indent=2)+"\n");print(json.dumps(result,indent=2))
raise SystemExit(0 if result["status"]=="PASS" else 1)
