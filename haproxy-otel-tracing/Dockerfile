FROM ubuntu:22.04 AS deps

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    cmake \
    ninja-build \
    pkg-config \
    curl \
    wget \
    gcc \
    g++ \
    zlib1g-dev \
    libssl-dev \
    ca-certificates \
    autoconf \
    automake \
    libtool \
    autoconf-archive \
    gettext-base \
    rsyslog \
    && rm -rf /var/lib/apt/lists/*

ARG OTEL_C_WRAPPER_VERSION=v2.2.0
ARG HAPROXY_VERSION=v3.5-dev1
ARG HAPROXY_OTEL_SHA=d7b406bfd9f7dabba8261131e8a9d0bef91ba6cd

RUN git clone --depth=1 -b "$OTEL_C_WRAPPER_VERSION" \
        https://github.com/haproxytech/opentelemetry-c-wrapper.git /opt/opentelemetry-c-wrapper \
    && rm -rf /opt/opentelemetry-c-wrapper/.git

RUN git clone --depth=1 -b "$HAPROXY_VERSION" \
        https://github.com/haproxy/haproxy.git /opt/haproxy \
    && rm -rf /opt/haproxy/.git

RUN git clone https://github.com/haproxytech/haproxy-opentelemetry.git /opt/haproxy-opentelemetry \
    && git -C /opt/haproxy-opentelemetry checkout "$HAPROXY_OTEL_SHA" \
    && rm -rf /opt/haproxy-opentelemetry/.git

WORKDIR /opt/opentelemetry-c-wrapper/scripts/build

RUN ./build-bundle.sh /opt

WORKDIR /opt/opentelemetry-c-wrapper

RUN ./scripts/bootstrap && \
    ./configure --prefix=/opt --with-opentelemetry=/opt && \
    make -j8 && \
    make install

RUN apt update

WORKDIR /opt/haproxy

FROM deps AS runtime

RUN PKG_CONFIG_PATH=/opt/lib/pkgconfig make -j8 TARGET=linux-glibc EXTRA_MAKE=/opt/haproxy-opentelemetry OTEL_USE_VARS=1

RUN cp /opt/haproxy/haproxy /usr/local/sbin/haproxy

# Create haproxy user and group for security
RUN groupadd -r haproxy && \
    useradd -r -g haproxy -s /sbin/nologin -c "HAProxy user" haproxy && \
    chown haproxy:haproxy /tmp && \
    chmod 1777 /tmp

COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY otel.cfg /usr/local/etc/haproxy/otel.cfg
COPY docker-entrypoint.sh /usr/local/etc/haproxy/docker-entrypoint.sh

ENTRYPOINT ["/bin/sh", "/usr/local/etc/haproxy/docker-entrypoint.sh"]
CMD ["/usr/local/sbin/haproxy", "-W", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
