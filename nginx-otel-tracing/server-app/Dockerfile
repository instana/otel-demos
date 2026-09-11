FROM azul/zulu-openjdk-alpine:11 AS nginx-tracing-server-app-build

RUN apk add --no-cache curl ca-certificates

WORKDIR /opt/server-app/
COPY . .
RUN ./mvnw clean package -DforkCount=0

FROM azul/zulu-openjdk-alpine:11-jre

VOLUME /tmp
WORKDIR /opt/server-app/
ARG JAR_FILE=target/server-app-1.0.0.RELEASE.jar
COPY --from=nginx-tracing-server-app-build /opt/server-app/${JAR_FILE} ./app.jar

ENTRYPOINT ["java","-jar","app.jar"]
