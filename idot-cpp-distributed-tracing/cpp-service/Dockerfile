# ─── Stage 1: download IDOT package and build ─────────────────────────────────
FROM ubuntu:22.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y && apt-get install -y --no-install-recommends \
        cmake \
        make \
        g++ \
        libcurl4-openssl-dev \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download cpp-httplib (single-header, no external deps)
ARG HTTPLIB_VERSION=0.16.0
RUN curl -fsSL \
    "https://github.com/yhirose/cpp-httplib/releases/download/v${HTTPLIB_VERSION}/httplib.h" \
    -o /tmp/httplib.h

# Download the IDOT OpenTelemetry C++ package.
# The IDOT_DOWNLOAD_KEY build-arg must be a valid Instana agent key.
ARG IDOT_VERSION=1.26.0
ARG IDOT_DOWNLOAD_KEY
ARG IDOT_PLATFORM=xLinux_64bit

RUN curl -fsSL \
    -u "_:${IDOT_DOWNLOAD_KEY}" \
    "https://artifact-public.instana.io/artifactory/rel-generic-instana-virtual/com/instana/idot-opentelemetry-cpp/${IDOT_VERSION}/idot-opentelemetry-cpp-${IDOT_VERSION}-bin.tar.gz" \
    | tar -xz -C /tmp

RUN tar -xzf "/tmp/idot-opentelemetry-cpp-${IDOT_VERSION}-${IDOT_PLATFORM}.tar.gz" \
        -C /opt/idot

# Build the C++ service
WORKDIR /src
COPY CMakeLists.txt .
COPY src/ src/
RUN mkdir -p vendor && cp /tmp/httplib.h vendor/httplib.h

RUN cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_PREFIX_PATH=/opt/idot && \
    cmake --build build -j$(nproc)

# ─── Stage 2: minimal runtime ──────────────────────────────────────────────────
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -y && apt-get install -y --no-install-recommends \
        libcurl4 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG IDOT_PLATFORM=xLinux_64bit
ARG IDOT_VERSION=1.26.0

COPY --from=build /opt/idot/lib64/                        /opt/idot/lib64/
COPY --from=build /src/build/cpp-service                  /app/cpp-service

ENV LD_LIBRARY_PATH=/opt/idot/lib64
ENV SERVER_PORT=8080

EXPOSE 8080
ENTRYPOINT ["/app/cpp-service"]
