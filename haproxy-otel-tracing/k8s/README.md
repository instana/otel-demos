# Kubernetes Deployments — HAProxy OTel Tracing

Two independent deployments inside the `haproxy-otel` namespace:

| Deployment | Image | Purpose |
|---|---|---|
| `haproxy` | `icr.io/instana-int/…/haproxy:3.5-otel.v1` | Reverse proxy with built-in OTel tracing filter |
| `instana-collector` | `icr.io/instana/idot:latest` | Instana OTel Collector (receives traces/metrics/logs via gRPC 4317) |

```
k8s/
├── namespace.yaml              # haproxy-otel namespace
├── secret.yaml                 # Instana credentials (edit before applying)
├── kustomization.yaml          # top-level — applies everything
├── haproxy/
│   ├── configmap.yaml          # haproxy.cfg · otel.cfg · otel.yml.template · entrypoint
│   ├── deployment.yaml         # Deployment + Service  (ports 10080, 8001)
│   └── kustomization.yaml
└── collector/
    ├── configmap.yaml          # collector config.yaml
    ├── deployment.yaml         # Deployment + Service  (port 4317 gRPC)
    └── kustomization.yaml
```

---

## 1 — Prerequisites

- Kubernetes ≥ 1.24
- `kubectl` CLI authenticated to the target cluster
- Image pull access to `icr.io` (IBM Cloud Container Registry)

If your cluster requires an image pull secret for `icr.io`:
```bash
kubectl create secret docker-registry icr-pull-secret \
  --docker-server=icr.io \
  --docker-username=iamapikey \
  --docker-password=<ICR_API_KEY> \
  -n haproxy-otel
```

---

## 2 — Configure credentials

Edit [`k8s/secret.yaml`](secret.yaml) and fill in the required values:

| Key | Description |
|---|---|
| `INSTANA_KEY` | Instana agent key |
| `INSTANA_OTEL_ENDPOINT_HTTP` | OTLPhttp backend, e.g. `https://<unit>.instana.io:4318` |
| `INSTANA_HOST_NAME` | Logical host name reported to Instana |

---

## 3 — Deploy

### Everything at once (recommended)
```bash
kubectl apply -k k8s/
```

### Individual deployments
```bash
# Collector only
kubectl apply -k k8s/collector/

# HAProxy only (collector must already be running)
kubectl apply -k k8s/haproxy/
```

---

## 4 — Verify

```bash
# Check pods
kubectl get pods -n haproxy-otel

# HAProxy stats page (port-forward)
kubectl port-forward -n haproxy-otel svc/haproxy 8001:8001
# open http://localhost:8001

# Collector health
kubectl port-forward -n haproxy-otel svc/instana-collector 13133:13133
curl http://localhost:13133/health

# Tail logs
kubectl logs -n haproxy-otel deploy/haproxy -f
kubectl logs -n haproxy-otel deploy/instana-collector -f
```

---

## 5 — Teardown

```bash
kubectl delete -k k8s/
# or delete only the namespace (removes everything inside it)
kubectl delete namespace haproxy-otel
```
