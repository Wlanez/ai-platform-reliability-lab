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
    export OPENROUTER_API_KEY="sk-or-v1-..."
    make scenario-agent-http-500

The default model is `openai/gpt-6.1-terra`. Override it with `AGENT_MODEL` for
cross-model evaluations.

The default output budget is `AGENT_MAX_OUTPUT_TOKENS=2000`. It limits generated
model output, not the evidence snapshot. This keeps diagnosis cost bounded and prevents
very large provider defaults from causing credit failures. If a model cannot complete
its structured diagnosis within the budget, that is visible as an evaluation/runtime
failure. Raise it deliberately when a scenario requires more output:

    AGENT_MAX_OUTPUT_TOKENS=4000 make scenario-agent-http-500

## Local artifacts

Runs write git-ignored files under artifacts/experiment-001/:

- agent-evidence.json
- agent-diagnosis.json
- agent-evaluation.json

The evaluator checks the expected application-level diagnosis, evidence grounding across
Kubernetes and Prometheus, successful read-only tool execution, confidence shape, and
whether the recommended first action is non-destructive.
