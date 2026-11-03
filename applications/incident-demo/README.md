# incident-demo

A deliberately fault-injectable Spring Boot service for Experiment 001.

## Modes

- `healthy`: `GET /api/work` returns HTTP 200.
- `errors`: `GET /api/work` returns HTTP 500.
- `latency`: `GET /api/work` waits about 1.5 seconds and returns HTTP 200.

The mode is changed through:

```http
POST /admin/failure?mode=healthy
POST /admin/failure?mode=errors
POST /admin/failure?mode=latency
```

Metrics are exposed at `/actuator/prometheus`.

The admin endpoint is intentionally simple because this application is only a lab workload. It must not be exposed outside the local experiment environment.
