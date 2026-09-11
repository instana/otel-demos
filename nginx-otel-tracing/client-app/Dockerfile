FROM azul/zulu-openjdk-alpine:11 AS nginx-tracing-client-app-build

RUN apk add --no-cache curl ca-certificates

WORKDIR /opt/client-app/
COPY . .
RUN ./mvnw clean package -DforkCount=0

FROM azul/zulu-openjdk-alpine:11-jre

VOLUME /tmp
WORKDIR /opt/client-app/
ARG JAR_FILE=target/client-app-1.0.0.RELEASE.jar
COPY --from=nginx-tracing-client-app-build /opt/client-app/${JAR_FILE} ./app.jar

ENTRYPOINT ["java","-jar","app.jar"]
