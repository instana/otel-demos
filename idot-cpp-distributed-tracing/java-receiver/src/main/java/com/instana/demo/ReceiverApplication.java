package com.instana.demo;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * java-receiver
 *
 * Accepts HTTP GET /ping from the C++ middle service.
 * Automatic instrumentation (via the auto-instrumentation agent attached to
 * this JVM) reads the W3C traceparent header injected by the C++ service and
 * creates a SERVER span that is a child of the C++ CLIENT span.
 *
 * No manual instrumentation is needed in this service.
 */
@SpringBootApplication
public class ReceiverApplication {

    private static final Logger log = LoggerFactory.getLogger(ReceiverApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(ReceiverApplication.class, args);
    }

    @RestController
    static class PingController {

        @GetMapping(value = "/ping", produces = MediaType.TEXT_PLAIN_VALUE)
        public String ping(@RequestHeader Map<String, String> headers) {
            log.info("Received /ping — traceparent: {}", headers.get("traceparent"));
            return "pong";
        }
    }
}
