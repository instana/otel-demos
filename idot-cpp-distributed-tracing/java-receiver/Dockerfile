# Stage 1: build
FROM eclipse-temurin:17-jdk-jammy AS build
WORKDIR /app
COPY . .
RUN ./mvnw -q clean package -DskipTests

# Stage 2: runtime with OTel Java Agent
FROM eclipse-temurin:17-jre-jammy

WORKDIR /app

# Download the OpenTelemetry Java Agent
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.5.0/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar

COPY --from=build /app/target/java-receiver-1.0.0.jar app.jar

ENV OTEL_SERVICE_NAME=java-receiver
ENV OTEL_EXPORTER_OTLP_PROTOCOL=grpc
ENV OTEL_LOGS_EXPORTER=none
ENV OTEL_METRICS_EXPORTER=none
ENV SERVER_PORT=8081

ENTRYPOINT ["java", \
  "-javaagent:/app/opentelemetry-javaagent.jar", \
  "-jar", "app.jar", \
  "--server.port=${SERVER_PORT}"]
