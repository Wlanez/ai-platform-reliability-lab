package dev.avangard.lab.incidentdemo;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.Logger;\nimport org.slf4j.LoggerFactory;\nimport org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.Instant;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

@RestController
public class IncidentController {

    private static final Set<String> VALID_MODES = Set.of("healthy", "errors", "latency");
    private final AtomicReference<String> mode = new AtomicReference<>("healthy");
    private final AtomicInteger modeCode = new AtomicInteger(0);
    private final Counter requests;
    private final Counter failures;

    public IncidentController(MeterRegistry registry) {
        this.requests = Counter.builder("incident_demo_requests")
                .description("Total calls to the demo workload endpoint")
                .register(registry);
        this.failures = Counter.builder("incident_demo_failures")
                .description("Injected HTTP failures returned by the demo")
                .register(registry);
        Gauge.builder("incident_demo_mode", modeCode, AtomicInteger::get)
                .description("Failure mode: 0=healthy, 1=errors, 2=latency")
                .register(registry);
    }

    @GetMapping("/api/work")
    public ResponseEntity<Map<String, Object>> work() throws InterruptedException {
        requests.increment();
        String currentMode = mode.get();

        if ("latency".equals(currentMode)) {
            Thread.sleep(1500);
        }

        if ("errors".equals(currentMode)) {
            failures.increment();
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                    .body(Map.of(
                            "status", "error",
                            "mode", currentMode,
                            "message", "Injected failure for EXP-001",
                            "timestamp", Instant.now().toString()));
        }

        return ResponseEntity.ok(Map.of(
                "status", "ok",
                "mode", currentMode,
                "message", "Incident demo workload completed",
                "timestamp", Instant.now().toString()));
    }

    @PostMapping("/admin/failure")
    public ResponseEntity<Map<String, String>> setFailureMode(@RequestParam String mode) {
        if (!VALID_MODES.contains(mode)) {
            return ResponseEntity.badRequest()
                    .body(Map.of("error", "mode must be one of: healthy, errors, latency"));
        }

        log.info("Changing incident mode from {} to {}", this.mode.get(), mode);\n        this.mode.set(mode);
        this.modeCode.set(switch (mode) {
            case "errors" -> 1;
            case "latency" -> 2;
            default -> 0;
        });

        return ResponseEntity.ok(Map.of("mode", mode));
    }

    @GetMapping("/admin/failure")
    public Map<String, String> getFailureMode() {
        return Map.of("mode", mode.get());
    }
}
