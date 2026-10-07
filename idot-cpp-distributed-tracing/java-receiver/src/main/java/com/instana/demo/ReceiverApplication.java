package com.instana.demo;

import com.ibm.mq.jms.MQConnectionFactory;
import com.ibm.msg.client.wmq.WMQConstants;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.MediaType;
import org.springframework.jms.annotation.EnableJms;
import org.springframework.jms.core.JmsTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;

import javax.jms.ConnectionFactory;
import java.util.Map;

/**
 * java-receiver
 *
 * Accepts HTTP GET /ping from cpp-service.
 * The Instana agent auto-instruments both entry points:
 *
 *   1. GET /ping — creates a SERVER span (child of the cpp-service CLIENT span).
 *   2. JmsTemplate.send() inside /ping — the agent creates a PRODUCER span
 *      (child of the SERVER span) for the IBM MQ message put to TEST.QUEUE.
 *
 * No manual instrumentation is needed in this service.
 */
@SpringBootApplication
@EnableJms
public class ReceiverApplication {

    private static final Logger log = LoggerFactory.getLogger(ReceiverApplication.class);

    public static void main(String[] args) {
        SpringApplication.run(ReceiverApplication.class, args);
    }

    // ── IBM MQ JMS configuration ──────────────────────────────────────────────

    @Configuration
    static class MqConfig {

        @Bean
        public ConnectionFactory mqConnectionFactory() throws Exception {
            String host    = System.getenv().getOrDefault("MQ_HOST",        "localhost");
            int    port    = Integer.parseInt(System.getenv().getOrDefault("MQ_PORT",    "1414"));
            String qmgr    = System.getenv().getOrDefault("MQ_QMGR",        "ACE.QUEUE.MANAGER");
            String channel = System.getenv().getOrDefault("MQ_CHANNEL",     "ACE.SVRCONN");

            MQConnectionFactory cf = new MQConnectionFactory();
            cf.setHostName(host);
            cf.setPort(port);
            cf.setQueueManager(qmgr);
            cf.setChannel(channel);
            cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);
            return cf;
        }

        @Bean
        public JmsTemplate jmsTemplate(ConnectionFactory mqConnectionFactory) {
            return new JmsTemplate(mqConnectionFactory);
        }
    }

    // ── HTTP endpoint: GET /ping ──────────────────────────────────────────────

    @RestController
    static class PingController {

        private final JmsTemplate jmsTemplate;

        PingController(JmsTemplate jmsTemplate) {
            this.jmsTemplate = jmsTemplate;
        }

        @GetMapping(value = "/ping", produces = MediaType.TEXT_PLAIN_VALUE)
        public String ping(@RequestHeader Map<String, String> headers) {
            String traceparent = headers.get("traceparent");
            log.info("[java-receiver] Received /ping — traceparent: {}", traceparent);
            // W3C traceparent format: 00-<traceId>-<parentSpanId>-<flags>
            if (traceparent != null) {
                String[] parts = traceparent.split("-");
                if (parts.length == 4) {
                    log.info("[java-receiver] Shared trace ID  : {}  parent span ID : {}", parts[1], parts[2]);
                }
            }

            // Put a message on IBM MQ.
            // The Instana agent auto-instruments this send() call and creates
            // a PRODUCER span as a child of the GET /ping SERVER span.
            String queue = System.getenv().getOrDefault("MQ_QUEUE", "TEST.QUEUE");
            jmsTemplate.send(queue, session ->
                session.createTextMessage("shipment-notification from java-receiver"));

            return "pong";
        }
    }
}
