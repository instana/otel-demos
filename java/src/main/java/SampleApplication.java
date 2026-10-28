// SampleApplication.java
// A sample application which allows us to utilize OpenTelemetry
package otel;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.sdk.OpenTelemetrySdk;
import io.opentelemetry.sdk.autoconfigure.AutoConfiguredOpenTelemetrySdk;
import io.opentelemetry.sdk.resources.Resource;
import io.opentelemetry.instrumentation.log4j.appender.v2_17.OpenTelemetryAppender;

import java.util.List;

@SpringBootApplication
public class SampleApplication {
    public static void main(String[] args) {
        SpringApplication.run(SampleApplication.class, args);

        // Create an instance of Sample
        Sample sample = new Sample();

        // Call playSample method and get the results
        List<Integer> results = sample.playSample(3);

        // Print the results
        System.out.println("Results: " + results);

        // Initialize OpenTelemetry
        initOpenTelemetry();
    }
}

// Method to initialize OpenTelemetry, which is called in main above
private static void initOpenTelemetry() {
    OpenTelemetrySdk sdk = AutoConfiguredOpenTelemetrySdk.builder().addResourceCustomizer((resource, properties) -> {
        Resource dtMetadata = Resource.empty();

        for (String name : new String[]{"dt_metadata_e617c525669e072eebe3d0f08212e8f2.properties", "/var/lib/dynatrace/enrichment/dt_metadata.properties"}) {
            try {
                Properties props = new Properties();
                props.load(name.startsWith("/var") ? new FileInputStream(name) : new FileInputStream(Files.readAllLines(Paths.get(name)).get(0)));
                dtMetadata = dtMetadata.merge(Resource.create(props.entrySet().stream()
                        .collect(Attributes::builder, (b, e) -> b.put(e.getKey().toString(), e.getValue().toString()), (b1, b2) -> b1.putAll(b2.build()))
                        .build())
                );
            } catch (IOException e) {
            }
        }

        return resource.merge(dtMetadata);
    }).build().getOpenTelemetrySdk();
    OpenTelemetryAppender.install(sdk);
}