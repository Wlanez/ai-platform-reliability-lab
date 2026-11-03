# MVP Architecture

## Design objective

Allow an AI SRE agent to investigate a Kubernetes incident while keeping authority, credentials, and policy enforcement outside the model.

## Trust boundaries

```text
                 UNTRUSTED / PROBABILISTIC
+--------------------------------------------------+
| User prompt                                     |
| LLM reasoning                                   |
| Application logs and retrieved text             |
+-------------------------+------------------------+
                          |
                          v
                 CONTROL BOUNDARY
                +------------------+
                | Tool/MCP Gateway |
                +--------+---------+
                         |
             +-----------+-----------+
             |                       |
             v                       v
      +-------------+          +------------+
      | Policy      |          | Audit /    |
      | Engine      |          | Telemetry  |
      +------+------+          +------------+
             |
             v
               TRUSTED EXECUTION
+--------------------------------------------------+
| Narrow Kubernetes API client                    |
| Prometheus query client                         |
| Bounded log/event reader                        |
+--------------------------------------------------+
```

## Components

### 1. Incident demo application

A small Spring Boot service deployed to a local Kubernetes cluster. It exposes health and Prometheus-compatible metrics and supports deterministic failure injection.

Initial failure modes:

- elevated HTTP 500 rate;
- artificial downstream latency;
- memory pressure or restart loop (later phase).

### 2. SRE investigator agent

Responsibilities:

- receive an incident objective;
- choose from an explicit list of tools;
- collect evidence;
- generate hypotheses;
- stop when evidence is sufficient or the budget is exhausted;
- produce a structured incident report.

The agent has no direct Kubernetes credentials.

### 3. Tool/MCP gateway

The gateway is the primary control point.

Each request should include:

- run ID;
- actor/agent ID;
- tool name;
- normalized arguments;
- requested resource/scope;
- timestamp;
- policy decision;
- decision reason;
- result status;
- duration;
- optional token/cost metadata.

The gateway validates requests before dispatching them.

### 4. Policy engine

Initial policies:

- allow only known tools;
- restrict Kubernetes operations to read-only verbs;
- restrict namespace to the experiment namespace;
- deny Secret access;
- enforce tool-call and time budgets;
- flag or deny dangerous requested actions.

OPA/Rego is a candidate implementation, but the policy contract matters more than the specific engine.

### 5. Execution adapters

Adapters translate approved tool requests into calls to Kubernetes, Prometheus, and logs.

Credentials belong here, not in the model context.

### 6. Audit and observability

OpenTelemetry should trace:

```text
investigation
  -> model turn
      -> tool request
          -> policy evaluation
          -> execution
          -> tool result
  -> final report
  -> evaluator
```

Prometheus/Grafana can track operational metrics; structured JSON events should remain the source for security/evaluation evidence.

## Safety invariant

> No model output is itself authorization.

Even if the model is prompt-injected or produces a dangerous request, deterministic controls must prevent an unauthorized cluster action.

## Initial deployment

The MVP should run locally:

- Docker
- kind
- Kubernetes
- Spring Boot
- Prometheus
- optional Grafana
- Python agent/gateway
- OPA
- OpenTelemetry

Cloud deployment comes later, after Experiment 001 is reproducible locally.
