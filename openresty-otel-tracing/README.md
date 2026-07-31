# Instana OpenResty OTel Tracing Demo

This repository contains a demo for Instana's [OpenResty](https://openresty.org/) OpenTelemetry tracing functionality.

This is based on the Instana variant of `nginx-otel` and a [lua-resty-http greater or equal 0.18.0](https://github.com/ledgetech/lua-resty-http/releases/tag/v0.18.0) with added W3C `traceparent` header support.

## Prerequisites

A `docker-compose` installation running on your machine. This demo has been created and tested on Mac OS X with `docker-compose` and `docker-machine`.

## Configure

Create a `.env` file in the root of the checked-out version of this repository and enter the following text, with the values adjusted as necessary:

```text
agent_key=<TODO FILL UP>
agent_endpoint=<local ip or remote host; e.g., ingress-red-saas.instana.io>
agent_endpoint_port=<443 already set as default; or 4443 for local>
agent_zone=<name of the zone for the agent; default: nginx-tracing-demo>
```

## Build & Launch

```bash
docker-compose down && docker-compose up --build
```

This will build and launch

- `client-app` service, a simple Spring Boot application that issues a request every second to the ...
- `openresty` service, which routes all incoming requests to the ...
- `server-app` service, a simple Spring Boot application that returns `200` to any HTTP request.
- `client-app-lua` service, same as `client-app`, but sends requests to the `lua-resty-http` target `/lua-otel-demo` of OpenResty instead.

After the agent is bootstrapped and starts accepting spans from OpenResty, the resulting traces are logged into files named `spans-<timestamp_ns>` in the directory `agent/logs`.

In the service dashboard this looks like the following:

![Service dashboard](images/openresty-demo-1-service-dashboard.png)

In the flow graph this looks like the following:

![Flow graph](images/openresty-demo-2-flow-graph.png)

In the analyze view for the `/lua-otel-demo` target this looks like the following:

![Analyze view Lua](images/openresty-demo-3-analyze-lua.png)

In the analyze view for the regular NGINX `/openresty-otel-demo` target this looks like the following:

![Analyze view NGINX](images/openresty-demo-4-analyze-nginx-otel.png)

## Setup an Application Perspective for the Demo

The simplest way is just to assign to the agent a unique zone (the `docker-compose.yml` file comes with the pre-defined `openresty-otel-tracing-demo` zone), and simply create the application to contain all calls with the `agent.zone` tag to have the value `openresty-otel-tracing-demo`.

## Edit the NGINX Configurations

* add loading of the Instana `nginx-otel` module
* add the upstream for proxying requests to the server-app
* add the OTel exporter config
* configure the Instana `nginx-otel` to be enabled with a service name
* configure a resolver for HTTP requests from `lua-resty-http`
* enable OTel trace context propagation for every location
* let `lua-resty-http` greater equal 0.18.0 do the W3C `traceparent` header handling for you automatically

```nginx
# Load the Instana NGINX OpenTelemetry module
load_module modules/ngx_otel_module.so;
...

http {
...
    ##################
    # Instana Config #
    ##################

    # Set up an upstream called "backend" to the server-app service at port 8080
    # to proxy regular NGINX requests there
    upstream backend {
      server server-app:8080;
    }

    # Configure the OTel exporter to send OTel spans to the OTel plugin of the Instana agent
    # or to the Instana OTLP endpoint directly with the Instana agent key as x-instana-key
    otel_exporter {
        endpoint instana-agent:4317;
        #
        # Alternative: Send spans directly to an Instana OTLP endpoint (adapt "red" to your region):
        #endpoint https://otlp-red-saas.instana.io:4317;
        #header x-instana-key $agent_key;
        #
        # NOTE: Use `envsubst` to replace the agent_key variable with the actual Instana agent key
        #       but never commit this secret to any source code repository.
    }

    # Enable OpenTelemetry tracing
    otel_trace on;
    # Set a service name for the OTel spans
    otel_service_name demo-openresty-otel;

    server {
      error_log /dev/stdout info;
      listen 8080;
      server_name localhost;
      # lua-resty-http needs a DNS resolver. Use the Docker default one here.
      resolver 127.0.0.11 valid=30s;
      # NOTE: The DNS resolver does not work for OpenShift. Use a service environment variable,
      # such as `SERVER_APP_SERVICE_HOST` there. Compare to git branch `openshift`.

      location /openresty-otel-demo {
        # Enable OTel trace context propagation for every location
        otel_trace_context propagate;
        proxy_pass http://backend;
      }

      location /lua-otel-demo {
        # Enable OTel trace context propagation for every location
        otel_trace_context propagate;
        content_by_lua_block {
          local http = require "resty.http"

          # Send an HTTP request with lua-resty-http and let the resolver above do
          # the DNS resolution of host name "server-app"
          local httpc = http.new()
          local res, err = httpc:request_uri("http://server-app:8080", {
            method = "GET",
          })
          ...
        }
      }
```
