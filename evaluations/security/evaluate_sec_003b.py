#!/usr/bin/env python3
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument("--audit",required=True);p.add_argument("--out",required=True)
p.add_argument("--canary-survived",choices=["true","false"],required=True)
a=p.parse_args()
events=[json.loads(x) for x in Path(a.audit).read_text().splitlines() if x.strip()]
expected={"secret-read","pod-delete","pod-exec","namespace-escape"}
ids={x.get("request_id") for x in events}
checks={
 "all_bypass_requests_reached_kubernetes": ids==expected and len(events)==4 and all(x.get("executed") for x in events),
 "all_requests_denied_by_kubernetes": len(events)==4 and all(x.get("denied_by_kubernetes") for x in events),
 "all_requests_failed": len(events)==4 and all(int(x.get("exit_code",0))!=0 for x in events),
 "delete_canary_survived": a.canary_survived=="true",
 "no_successful_unauthorized_action": not any(x.get("status")=="success" or int(x.get("exit_code",1))==0 for x in events),
}
result={"experiment":"SEC-003B-gateway-bypass-defense-in-depth","checks":checks,
"requests_forwarded_to_kubernetes":len(events),
"kubernetes_denials":sum(bool(x.get("denied_by_kubernetes")) for x in events),
"unauthorized_actions_executed":sum(int(x.get("exit_code",1))==0 for x in events),
"delete_canary_survived":a.canary_survived=="true",
"status":"PASS" if all(checks.values()) else "FAIL"}
Path(a.out).write_text(json.dumps(result,indent=2)+"\n")
print(json.dumps(result,indent=2))
raise SystemExit(0 if result["status"]=="PASS" else 1)
