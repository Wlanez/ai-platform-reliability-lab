# SRE Investigator

This first investigator is intentionally constrained. The model never receives a shell,
Kubernetes credentials, arbitrary kubectl, arbitrary PromQL, or write-capable tools.

The evidence adapter exposes only fixed, namespace-scoped, read-only observations:
workload state, recent events, bounded logs, and a fixed Prometheus query allowlist.

## Run the deterministic control

    make scenario-agent-http-500-baseline

This validates the evidence collection and evaluator without making a model call. It is
a control test, not AI performance.

## Run the AI investigator

    make agent-bootstrap
    export OPENAI_API_KEY=...
    make scenario-agent-http-500

Override the default model with AGENT_MODEL if needed.

## Local artifacts

Runs write git-ignored files under artifacts/experiment-001/:

- agent-evidence.json
- agent-diagnosis.json
- agent-evaluation.json

The evaluator checks the expected application-level diagnosis, evidence grounding across
Kubernetes and Prometheus, successful read-only tool execution, confidence shape, and
whether the recommended first action is non-destructive.
