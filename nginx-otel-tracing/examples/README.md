# NGINX OTel tracing — sampling examples

Each file in this directory is a self-contained `nginx.conf` demonstrating one
sampling strategy for the Instana NGINX OTel tracing module. All files share the
same base structure as `nginx/nginx.conf` in the parent demo project.

## Files

| File | Strategy |
|------|----------|
| `nginx.always-on.conf` | Always-on — every request is traced |
| `nginx.always-off.conf` | Always-off — tracing suppressed for a specific location |
| `nginx.ratio-trace-id.conf` | Ratio-based by trace ID — consistent per-trace decision |
| `nginx.ratio-session-id.conf` | Ratio-based by session ID — consistent per-session decision |
| `nginx.parent-based.conf` | Parent-based — decision delegated to the upstream caller |

---

## Built-in OTel variables

The module exposes these read-only variables that sampling configurations can use:

| Variable | Description |
|----------|-------------|
| `$otel_trace_id` | Current trace ID (32-character hex). Inherited from upstream or newly generated. |
| `$otel_span_id` | Current span ID (16-character hex). |
| `$otel_parent_id` | Parent span ID (16-character hex). |
| `$otel_parent_sampled` | `1` if the upstream request was marked as sampled; `0` otherwise. |

---

## How `otel_trace` works

`otel_trace` accepts any NGINX complex value. At request time the module
evaluates the value and creates a span only when it resolves to `on` or `1`.
When it resolves to `off` or `0`, no span is created and no data is sent to the
backend; the request continues to proxy normally.

---

## Strategy details

### Always-on (`nginx.always-on.conf`)

`otel_trace on` is set at the server block level, so every request is traced.
The `/nginx_status` location overrides this to `otel_trace off` to suppress the
nginx stub-status endpoint.

Use this in development, debugging, or when full trace visibility is required.
It is equivalent to a 100 % sampling rate.

**Verify:** send a request and check **Analytics → Calls** in the Instana UI,
filtering by `service.name = "nginx-otel-proxy"`. Every request must produce a
call entry.

---

### Always-off (`nginx.always-off.conf`)

`otel_trace off` inside a location block overrides any server-level `otel_trace`
directive and completely suppresses tracing for that location. No span is created
and no data is sent to the trace backend.

Use this pattern to prevent high-frequency or noisy endpoints — such as
`/nginx_status` — from polluting the trace store, without removing the
`otel_exporter` block.

**Verify:** requests to the configured location must not appear in
**Analytics → Calls**.

---

### Ratio-based by trace ID (`nginx.ratio-trace-id.conf`)

`split_clients` hashes `$otel_trace_id` using the MurmurHash algorithm and
assigns the result to `$ratio_sampler`. Because the same trace ID always
produces the same hash, the sampling decision is stable for the entire lifetime
of a trace.

When `otel_trace_context propagate` is set, `$otel_trace_id` is inherited from
the incoming `traceparent` or `X-INSTANA-T` header, so the NGINX decision
follows the upstream decision and remains consistent end-to-end.

The default configuration samples **10 %** of requests. Adjust the percentage in
the `split_clients` block to change the rate. At least 100 requests are needed
to observe the configured ratio reliably.

**Verify:** temporarily add the following inside the `location /` block, then
remove it after testing:

```nginx
add_header X-Sampled $ratio_sampler always;
```

Send 100 requests and count the responses where `X-Sampled: on` appears.

---

### Ratio-based by session ID (`nginx.ratio-session-id.conf`)

`split_clients` hashes the value of a session cookie so that every request
belonging to a given session receives an identical sampling decision for the
duration of that session.

Replace `$cookie_sessionid` in the `split_clients` directive with the cookie
name your application uses:

| Cookie variable | Framework |
|-----------------|-----------|
| `$cookie_JSESSIONID` | Spring Boot / Apache Tomcat |
| `$cookie_SESSION` | Spring Session |
| `$cookie_PHPSESSID` | PHP |
| `$cookie_connect.sid` | Node.js / Express |

If a request carries no session cookie, the empty string is hashed to a fixed
bucket and the result is deterministic (consistently `on` or `off`). For
cookie-free clients, use ratio-based sampling by trace ID instead.

The default configuration samples **10 %** of sessions. Adjust the percentage in
the `split_clients` block to change the rate.

**Verify:** temporarily add the following inside the `location /` block, then
remove it after testing:

```nginx
add_header X-Sampled $session_sampler always;
```

Use `curl -b "sessionid=<value>"` with different cookie values and confirm that
the same cookie value consistently returns the same `X-Sampled` header.

---

### Parent-based (`nginx.parent-based.conf`)

`$otel_parent_sampled` is a built-in read-only variable populated by the module
after `otel_trace_context propagate` extracts the incoming trace headers. It
resolves to `1` when the upstream caller has marked the request as sampled, and
`0` otherwise.

By passing `$otel_parent_sampled` directly to `otel_trace`, NGINX delegates the
sampling decision entirely to the calling service.

> **Important:** `otel_trace_context propagate` is required. Without it,
> `$otel_parent_sampled` is never populated and is always `0`, so no spans would
> ever be created regardless of incoming headers.

**Supported incoming header formats** (evaluated in this order):

1. Instana headers: `X-INSTANA-L: 1` (sampled) or `X-INSTANA-L: 0` (not sampled).
2. W3C `traceparent`: flags byte `01` (sampled) or `00` (not sampled).

When both Instana and W3C headers are present, Instana headers take priority.
When no headers are present, `$otel_parent_sampled` is `0` and no span is
created.

**Verify** by sending requests with explicit headers and checking
**Analytics → Calls** in the Instana UI:

```sh
# Instana headers — sampled: span must appear.
curl -H "X-INSTANA-T: 8448eb211c80319c" \
     -H "X-INSTANA-S: b9c7c989f97918e1" \
     -H "X-INSTANA-L: 1" \
     http://localhost:10080/

# Instana headers — not sampled: no span must appear.
curl -H "X-INSTANA-T: 8448eb211c80319c" \
     -H "X-INSTANA-S: b9c7c989f97918e1" \
     -H "X-INSTANA-L: 0" \
     http://localhost:10080/

# No headers: no span must appear.
curl http://localhost:10080/

# W3C traceparent sampled (flags=01): span must appear.
curl -H "Traceparent: 00-0af7651916cd43dd8448eb211c80319c-b9c7c989f97918e1-01" \
     http://localhost:10080/

# W3C traceparent not sampled (flags=00): no span must appear.
curl -H "Traceparent: 00-0af7651916cd43dd8448eb211c80319c-b9c7c989f97918e1-00" \
     http://localhost:10080/
```
