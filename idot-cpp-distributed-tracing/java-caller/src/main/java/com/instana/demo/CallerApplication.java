package com.instana.demo;

import io.opentelemetry.api.trace.Span;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.web.client.RestTemplateBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.http.MediaType;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;

/**
 * java-caller
 *
 * Forwards HTTP GET /order to the C++ middle service.
 * Automatic instrumentation (via the auto-instrumentation agent attached to
 * this JVM) creates a CLIENT span for each outbound RestTemplate call and
 * injects W3C traceparent / tracestate headers into the request automatically.
 *
 * No manual instrumentation is needed in this service.
 *
 * Usage:
 *   Trigger a single trace:
 *     curl http://localhost:8082/order
 *
 *   Enable continuous traffic (one call every 5 s):
 *     Set environment variable SCHEDULE_ENABLED=true before starting.
 */
@SpringBootApplication
@EnableScheduling
public class CallerApplication {

    private static final Logger log = LoggerFactory.getLogger(CallerApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(CallerApplication.class, args);
    }

    @Bean
    RestTemplate restTemplate(RestTemplateBuilder builder) {
        return builder
                .setConnectTimeout(Duration.ofSeconds(3))
                .setReadTimeout(Duration.ofSeconds(10))
                .build();
    }

    @RestController
    static class OrderController {

        private final RestTemplate restTemplate;
        private final String cppServiceUrl;

        OrderController(
                RestTemplate restTemplate,
                @Value("${CPP_SERVICE_URL:http://localhost:8080}") String cppServiceUrl) {
            this.restTemplate = restTemplate;
            this.cppServiceUrl = cppServiceUrl;
        }

        /**
         * Trigger a single end-to-end trace:
         *   curl http://localhost:8082/order
         */
        @GetMapping(value = "/order", produces = MediaType.TEXT_PLAIN_VALUE)
        public String order() {
            // The OTel Java agent instruments this method and makes its span the
            // current span.  Span.current() reads the trace/span IDs directly
            // from the agent's context — no header parsing needed.
            Span span = Span.current();
            String traceId = span.getSpanContext().getTraceId();
            String spanId  = span.getSpanContext().getSpanId();
            log.info("[java-caller] Root trace ID : {}  span ID : {}", traceId, spanId);

            String response = restTemplate.getForObject(cppServiceUrl + "/order", String.class);
            log.info("[java-caller] Response from C++ service: {}", response);
            return response;
        }
    }

    /**
     * Optional continuous traffic generator.
     * Enabled only when SCHEDULE_ENABLED=true (disabled by default).
     * Fires one GET /order every CALL_INTERVAL_MS milliseconds (default: 5000).
     */
    static class ScheduledCaller {

        private final RestTemplate restTemplate;
        private final String cppServiceUrl;
        private final boolean enabled;

        ScheduledCaller(RestTemplate restTemplate, String cppServiceUrl, boolean enabled) {
            this.restTemplate = restTemplate;
            this.cppServiceUrl = cppServiceUrl;
            this.enabled = enabled;
        }

        @Scheduled(fixedDelayString = "${CALL_INTERVAL_MS:5000}")
        void callCppService() {
            if (!enabled) return;
            try {
                String response = restTemplate.getForObject(cppServiceUrl + "/order", String.class);
                log.info("[scheduled] Response from C++ service: {}", response);
            } catch (Exception ex) {
                log.warn("[scheduled] Call to C++ service failed: {}", ex.getMessage());
            }
        }
    }

    @Bean
    ScheduledCaller scheduledCaller(
            RestTemplate restTemplate,
            @Value("${CPP_SERVICE_URL:http://localhost:8080}") String cppServiceUrl,
            @Value("${SCHEDULE_ENABLED:false}") boolean scheduleEnabled) {
        return new ScheduledCaller(restTemplate, cppServiceUrl, scheduleEnabled);
    }
}
