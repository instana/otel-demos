FROM azul/zulu-openjdk:11 AS istio-tracing-middle-app-build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y && apt-get install -y --no-install-recommends --no-install-suggests \
    curl \
    ca-certificates

WORKDIR /opt/middle-app/
COPY . .
RUN ./mvnw clean package

FROM azul/zulu-openjdk:11

VOLUME /tmp
WORKDIR /opt/middle-app/
ARG JAR_FILE=target/middle-app-1.0.0.RELEASE.jar
COPY --from=istio-tracing-middle-app-build /opt/middle-app/${JAR_FILE} ./app.jar

ENTRYPOINT ["java","-jar","app.jar"]
