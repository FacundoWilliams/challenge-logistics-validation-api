# Logistics Validation API

> REST API for payload integrity validation via canonical MD5 hashing.
> Built with FastAPI · Uvicorn · Nginx · Docker · GitHub Actions.

[![CI](https://github.com/<org>/logistics-api-challenge/actions/workflows/ci.yml/badge.svg)](https://github.com/<org>/logistics-api-challenge/actions/workflows/ci.yml)
![Python](https://img.shields.io/badge/Python-3.12-blue?logo=python)
![FastAPI](https://img.shields.io/badge/FastAPI-0.115.5-009688?logo=fastapi)
![Docker](https://img.shields.io/badge/Docker-multistage-2496ED?logo=docker)
![License](https://img.shields.io/badge/License-Private-lightgrey)

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Endpoint Reference](#2-endpoint-reference)
3. [Technical Decisions & Architecture](#3-technical-decisions--architecture)
4. [CI/CD Pipeline](#4-cicd-pipeline)
5. [Scripts Reference](#5-scripts-reference)
6. [Risks, Assumptions & Production Roadmap](#6-risks-assumptions--production-roadmap)
7. [Tech Stack](#7-tech-stack)
8. [Known Troubleshooting](#8-known-troubleshooting)

---

## 1. Quick Start

### Prerequisites

| Tool | Minimum version | Purpose |
|---|---|---|
| Docker Engine | 24.x | Container runtime |
| Docker Compose | v2 plugin | Stack orchestration |
| Bash | 4.x | Automation scripts |
| curl | any | Manual testing & healthcheck |
| Python | 3.12 | Local test execution (optional) |

### 1.1 Clone and configure

```bash
git clone https://github.com/<org>/logistics-api-challenge.git
cd logistics-api-challenge

# Copy the environment template — edit values as needed
cp .env.example .env
```

### 1.2 Build the Docker image

```bash
./scripts/build.sh
```

This builds the multistage image and applies two tags: `logistics-api:local`
(stable dev alias) and `logistics-api:<git-sha>` (commit traceability).
Pass `--no-cache` for a fully clean build:

```bash
./scripts/build.sh --no-cache
```

### 1.3 Start the full stack

```bash
./scripts/start.sh
```

The script brings up both services in detached mode and polls
`http://localhost/health` (through Nginx) until the stack is ready.
When it prints the ready banner, both containers are healthy.

```
[2025-01-15 10:00:01] [OK] =============================================
[2025-01-15 10:00:01] [OK]  Stack is UP and healthy!
[2025-01-15 10:00:01] [OK] =============================================
[2025-01-15 10:00:01] [OK]   API (via Nginx) : http://localhost/health
[2025-01-15 10:00:01] [OK]   Swagger UI      : http://localhost/docs
```

### 1.4 Explore the Swagger UI

```
http://localhost/docs      # Swagger UI — interactive API explorer
http://localhost/redoc     # ReDoc — alternative documentation view
http://localhost/openapi.json  # Raw OpenAPI 3.1 schema
```

---

## 2. Endpoint Reference

### 2.1 `GET /health`

Liveness probe. Returns `200 OK` when the service is running.

```bash
curl -s http://localhost/health | python3 -m json.tool
```

```json
{
  "status": "ok",
  "version": "1.0.0"
}
```

---

### 2.2 `POST /validate-md5`

Validates that a supplied MD5 hex digest matches the canonical JSON
representation of a given payload.

#### Request body schema

| Field | Type | Required | Description |
|---|---|---|---|
| `payload` | `object` | Yes | Any JSON object whose integrity will be validated |
| `md5_hash` | `string` | Yes | 32-character lowercase hexadecimal MD5 digest |

`md5_hash` is validated by Pydantic before any business logic executes.
Non-hex characters or wrong length return `422` immediately.

---

#### Case 1 — Valid: hash matches the payload

First, compute the canonical MD5 of your payload locally:

```bash
python3 -c "
import hashlib, json
payload = {'order_id': 42, 'status': 'shipped'}
canonical = json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=True)
print('Canonical :', canonical)
print('MD5       :', hashlib.md5(canonical.encode('utf-8')).hexdigest())
"
```

```
Canonical : {"order_id":42,"status":"shipped"}
MD5       : 9b474df2b5f7503427d0b7932e26c5e3
```

Then POST it (note: key order in the request does **not** matter — the server canonicalises before hashing):

```bash
curl -s -X POST http://localhost/validate-md5 \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {"status": "shipped", "order_id": 42},
    "md5_hash": "9b474df2b5f7503427d0b7932e26c5e3"
  }' | python3 -m json.tool
```

```json
{
  "valid": true,
  "md5": "9b474df2b5f7503427d0b7932e26c5e3",
  "canonical_json": "{\"order_id\":42,\"status\":\"shipped\"}"
}
```

The response includes `canonical_json` — the exact UTF-8 string that was fed
to the MD5 function — enabling full client-side auditability.

---

#### Case 2 — Invalid: hash does not match the payload

```bash
curl -s -X POST http://localhost/validate-md5 \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {"order_id": 42, "status": "shipped"},
    "md5_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }' | python3 -m json.tool
```

```json
{
  "detail": "MD5 mismatch. Expected: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', Computed: '9b474df2b5f7503427d0b7932e26c5e3' over canonical JSON: '{\"order_id\":42,\"status\":\"shipped\"}'"
}
```

HTTP status: **422 Unprocessable Entity**

---

#### Case 3 — Malformed: `md5_hash` has wrong format

```bash
curl -s -X POST http://localhost/validate-md5 \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {"order_id": 42},
    "md5_hash": "not-a-valid-hash"
  }' | python3 -m json.tool
```

```json
{
  "detail": [
    {
      "type": "value_error",
      "loc": ["body", "md5_hash"],
      "msg": "Value error, md5_hash must be a 32-character lowercase hexadecimal string.",
      "input": "not-a-valid-hash"
    }
  ]
}
```

HTTP status: **422 Unprocessable Entity** (Pydantic rejects the field before any business logic runs)

---

#### Case 4 — Monitor health continuously

```bash
./scripts/healthcheck.sh
```

```
[2025-01-15 10:00:05] [ INFO ] Endpoint : http://localhost/health
[2025-01-15 10:00:05] [ INFO ] Interval : 5s  |  Press Ctrl+C to stop
[2025-01-15 10:00:05] [  UP  ] http://localhost/health responded HTTP 200
[2025-01-15 10:00:10] [  UP  ] http://localhost/health responded HTTP 200
[2025-01-15 10:00:15] [ DOWN ] Connection refused or timed out (consecutive failures: 1)
```

---

#### Stop the stack

```bash
./scripts/stop.sh               # Stop and remove containers + network
./scripts/stop.sh --volumes     # Also remove named volumes
./scripts/stop.sh --rmi         # Also remove built images
```

---

## 3. Technical Decisions & Architecture

### 3.1 Why FastAPI?

FastAPI was chosen over Flask, Django REST Framework, and other Python options based on four concrete engineering advantages:

**Native OpenAPI 3.1 generation with zero configuration.**
The Swagger UI at `/docs` and the schema at `/openapi.json` are generated
automatically from Python type hints and Pydantic models. There is no separate
documentation file to maintain and no risk of docs drifting from the
implementation.

**Pydantic v2 validation at the boundary.**
Every request field is parsed and validated before any application code runs.
The `md5_hash` field is rejected with a structured 422 error if it is not a
32-character hexadecimal string — no hand-written validation code required.
This shifts validation left and keeps the router layer thin.

**Modern async-native design.**
FastAPI is built on Starlette and runs on Uvicorn's ASGI server. Even though
the MD5 computation is synchronous, the architecture is ready for async
database calls, outbound HTTP requests, or background tasks without a rewrite.

**Production-ready defaults.**
Request body size limits, automatic 422 error serialisation, structured
exception handlers, and CORS middleware are all first-class features, not
third-party plugins.

---

### 3.2 Network topology

```
                    ┌─────────────────────────────────┐
 Internet / Host    │      Docker bridge: logistics_net│
                    │                                  │
  :80 ──────────► [nginx:80]                          │
                    │   proxy_pass http://api:8000     │
                    │         ↓                        │
                    │     [api:8000]   ← NOT published │
                    │   FastAPI/Uvicorn                │
                    └─────────────────────────────────┘
```

Port `8000` is declared with `expose:` in `docker-compose.yml`, not `ports:`.
This makes it reachable only within `logistics_net`. The host and the internet
can only reach the application through Nginx on port `80`. This ensures all
security headers, timeout controls, and payload size limits enforced by Nginx
cannot be bypassed.

---

### 3.3 The canonical MD5 problem

#### Why naive hashing fails

JSON (RFC 8259) does not mandate key ordering in objects. Two calls to a
JSON serialiser from different languages — or even different versions of the
same library — may produce different byte sequences for semantically identical
objects:

```
{"a": 1, "b": 2}   →   MD5: d0a5a7f3...
{"b": 2, "a": 1}   →   MD5: 9e107d9d...   ← different hash, same data
```

Any hashing scheme that operates on raw JSON bytes is therefore
**non-deterministic** across clients. The server and the client will compute
different hashes for the same logical payload unless they agree on an exact
serialisation form.

#### The canonical form

The solution defines one unambiguous serialisation contract:

```python
import hashlib, json

def compute_md5(payload: dict) -> tuple[str, str]:
    canonical = json.dumps(
        payload,
        sort_keys=True,        # Rule 1 — lexicographic key order
        separators=(',', ':'), # Rule 2 — no whitespace between tokens
        ensure_ascii=True,     # Rule 3 — non-ASCII → \uXXXX escapes
    )
    digest = hashlib.md5(canonical.encode('utf-8')).hexdigest()
    return digest, canonical
```

| Rule | Parameter | Value | Justification |
|---|---|---|---|
| Key ordering | `sort_keys` | `True` | Lexicographic sort eliminates insertion-order dependency across all clients and languages |
| Separators | `separators` | `(',', ':')` | No whitespace eliminates the ambiguity between compact `{"a":1}` and pretty-printed `{"a": 1}` |
| Char encoding | `ensure_ascii` | `True` | Non-ASCII characters are serialised as `\uXXXX` escape sequences, preventing divergence between systems with different locale codecs |
| Byte encoding | `.encode()` | `'utf-8'` | UTF-8 is the unambiguous byte-level representation; required before any hashing function |
| Excluded field | `md5_hash` | omitted | Hashing the hash would be circular — only `payload` is canonicalised |

This approach mirrors the intent of JSON Canonicalization Scheme (JCS, RFC 8785)
without introducing an external dependency, and is fully reproducible in any
language with a standard JSON library:

```python
# Python
json.dumps(payload, sort_keys=True, separators=(',', ':'))

# Node.js
JSON.stringify(Object.keys(payload).sort().reduce((o, k) => ({ ...o, [k]: payload[k] }), {}))

# Go
// encoding/json marshals struct fields in declaration order;
// use a sorted-keys map or a custom marshaller
```

#### Why 422 and not 400 on hash mismatch

HTTP 400 Bad Request signals a malformed or unparseable message.
HTTP 422 Unprocessable Entity (RFC 9110 §15.5.21) signals that the request
is syntactically valid but semantically incorrect. A hash mismatch is a
semantic integrity failure — the JSON parsed correctly, but the claimed
fingerprint does not match the computed fingerprint. Using 422 is consistent
with how FastAPI signals its own validation failures and clearly communicates
the nature of the error to API consumers.

---

### 3.4 Dockerfile: multistage build

```dockerfile
# Stage 1 — builder: install deps into /install prefix
FROM python:3.12-slim AS builder
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2 — runner: copy only the wheel artifacts + source
FROM python:3.12-slim AS runner
COPY --from=builder /install /usr/local
COPY app/ ./app/
```

The `builder` stage contains pip, setuptools, wheel, and any native
compilers. None of these reach the final image. The `runner` image
ships only the installed packages and the application source.

Security hardening in the runner stage:

- `apt-get upgrade -y` at build time — patches known CVEs in the base image
- Non-root user (`appuser`, no shell, no home directory) — limits blast radius of a container escape
- `HEALTHCHECK` via stdlib `urllib.request` — no runtime dependency on `curl`
- `.dockerignore` excludes `.git`, `tests/`, `__pycache__`, `.env`, and all dev artifacts

---

### 3.5 Nginx security directives

| Directive | Value | Risk mitigated |
|---|---|---|
| `server_tokens` | `off` | Hides Nginx version from error pages and `Server` header |
| `X-Content-Type-Options` | `nosniff` | Prevents MIME-sniffing attacks |
| `X-Frame-Options` | `DENY` | Blocks clickjacking via iframe embedding |
| `X-XSS-Protection` | `1; mode=block` | Legacy browser XSS filter |
| `Cache-Control` | `no-store` | Prevents caching of sensitive response data |
| `client_max_body_size` | `512k` | Rejects oversized bodies at the proxy layer (DoS mitigation) |
| `proxy_connect_timeout` | `5s` | Limits slow TCP connection exhaustion |
| `proxy_read_timeout` | `30s` | Limits slow-read / Slowloris-style attacks |
| `location ~ /\.` | `deny all` | Blocks access to dot-files (`.git`, `.env`) |
| `keepalive` | `32` | Reuses TCP connections to the upstream (performance) |

All security headers use the `always` flag so they are added to `4xx` and `5xx`
responses as well as `2xx`.

---

## 4. CI/CD Pipeline

### Pipeline overview

```
push / pull_request
        │
        ▼
┌──────────────────┐     fail → stop
│  lint-and-test   │ ──────────────────────────────►  ✗
│  Ruff + pytest   │
└──────────┬───────┘
           │ pass
           ▼
┌──────────────────┐     fail → stop
│  docker-build    │ ──────────────────────────────►  ✗
│  BuildX + cache  │
└──────────┬───────┘
           │ pass
           ▼
┌──────────────────┐
│  integration     │
│  Compose up      │
│  curl /health    │
│  curl /validate  │
│  Compose down    │
└──────────────────┘
```

### Stage breakdown

**`lint-and-test`** — runs on every push and PR, no Docker required.
Installs dependencies from the pip cache, runs Ruff for style and bug
detection with `--output-format=github` (renders inline PR annotations),
and runs pytest with coverage. Coverage is uploaded as a build artefact
and retained for 14 days.

**`docker-build`** — runs only after tests pass. Uses
`docker/build-push-action` with the GitHub Actions cache backend
(`type=local`). The cache key is computed from the hash of
`requirements.txt` and `Dockerfile`, so it is invalidated precisely
when dependencies or build steps change. The "cache dance"
(`/tmp/.buildx-cache-new` → rename → `/tmp/.buildx-cache`) prevents
unbounded cache growth across workflow runs. Image size is reported to
the job summary.

**`integration`** — runs the full Compose stack on the GitHub-hosted
runner and validates the live system:

1. Polls `docker inspect --format='{{.State.Health.Status}}'` until the `api` container is `healthy`
2. Sends `GET http://localhost/health` through Nginx, asserts `HTTP 200` and `"status": "ok"` in the body
3. Computes the canonical MD5 inline with Python, sends `POST http://localhost/validate-md5`, asserts `HTTP 200`
4. Tears down the stack unconditionally (`if: always()`)
5. Writes a results table to `$GITHUB_STEP_SUMMARY`

### Concurrency control

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

A new push to the same branch cancels any in-flight run immediately,
preventing queue build-up and wasted runner minutes.

---

## 5. Scripts Reference

All scripts use `set -euo pipefail`:
- `-e` exits immediately on any non-zero return code
- `-u` treats unset variables as errors
- `-o pipefail` propagates failures through pipes

| Script | Key options | Description |
|---|---|---|
| `build.sh` | `--no-cache` | Builds `logistics-api:local` and `logistics-api:<git-sha>`. Reports final image size. |
| `start.sh` | `--build`, `--env-file <path>` | Starts the Compose stack in detached mode. Polls `/health` via Nginx until ready. Prints Swagger URL on success. |
| `stop.sh` | `--volumes`, `--rmi` | Stops containers and removes the network. `--volumes` deletes data. `--rmi` removes images (forces full rebuild). |
| `healthcheck.sh` | `--url <url>`, `--interval <s>` | Infinite loop. Polls `/health` every 5 s. Prints timestamped `UP`/`DOWN` with consecutive failure counter. ANSI colours disabled automatically in non-TTY environments (CI logs, pipes). |

---

## 6. Risks, Assumptions & Production Roadmap

This section addresses the conceptual and architectural gap between the
current local-development implementation and a hardened, large-scale
production deployment. Each subsection maps a known risk to its
industry-standard mitigation.

---

### 6.1 Deployment, Versioning & Rollbacks

#### Current state
Docker Compose with a single replica per service. Useful for local
development and CI validation. Not suitable for zero-downtime production
deployments.

#### Production target: Kubernetes

Container images are tagged with the Git SHA at build time
(`logistics-api:a3f9c1b`). This tag is immutable — a given tag always
refers to the same build. The CI pipeline pushes to a **private
container registry** (AWS ECR, Google Artifact Registry, or GitHub
Container Registry with access controls). Public registries are not
used in production because they expose image metadata and have no
access audit trail.

**Deployment strategy — Blue/Green for this service:**

Blue/Green is appropriate for a stateless API with no schema migrations.
Two identical environments (Blue = current, Green = next) are maintained.
Traffic is switched at the load balancer level once the Green environment
passes its health gates. Rollback is instantaneous — switch the load
balancer back to Blue. No pod restarts are required.

```
Load Balancer
    │
    ├── Blue  (v1.2.0 — 100% traffic, current)
    └── Green (v1.3.0 — 0% traffic, being validated)

After validation passes:
    ├── Blue  (v1.2.0 — 0% traffic, standby for rollback)
    └── Green (v1.3.0 — 100% traffic, active)
```

**Alternative — Canary for gradual confidence:**

If the change carries higher risk (e.g. a change to the canonicalisation
algorithm), a Canary deployment shifts traffic incrementally:
1% → 5% → 25% → 100%, with automated rollback if the error rate or p99
latency exceed defined thresholds in Prometheus.

**Kubernetes manifest pattern:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logistics-api
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0     # Never reduce capacity during rollout
      maxSurge: 1           # Bring one new pod up before taking one down
  selector:
    matchLabels:
      app: logistics-api
  template:
    metadata:
      labels:
        app: logistics-api
        version: "a3f9c1b"  # Git SHA embedded as a label for traceability
    spec:
      containers:
        - name: api
          image: 123456789.dkr.ecr.us-east-1.amazonaws.com/logistics-api:a3f9c1b
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
```

---

### 6.2 Observability

#### Logs

In production, Uvicorn's default text log format is replaced with
**structured JSON logging**. Each log line is a parseable JSON object
with consistent fields:

```json
{
  "timestamp": "2025-01-15T10:00:00.123Z",
  "level": "info",
  "service": "logistics-api",
  "version": "1.3.0",
  "request_id": "f7a3b2c1-...",
  "method": "POST",
  "path": "/validate-md5",
  "status_code": 200,
  "duration_ms": 3.2,
  "client_ip": "10.0.0.15"
}
```

A `request_id` (UUID generated per request or propagated from an upstream
`X-Request-ID` header) allows a single transaction to be traced across
Nginx access logs, FastAPI application logs, and any downstream services.
Logs are shipped to a centralised aggregation system (AWS CloudWatch
Logs, Google Cloud Logging, or a self-hosted Loki stack) and retained
according to compliance policy.

#### Metrics

The application exposes a `/metrics` endpoint (via the `prometheus-fastapi-instrumentator`
library) with the following key indicators:

| Metric | Type | Alert condition |
|---|---|---|
| `http_requests_total` | Counter | Sudden spike → potential abuse |
| `http_request_duration_seconds` | Histogram | p99 > 500 ms → SLA breach |
| `http_requests_errors_total` | Counter | 5xx rate > 1% → immediate alert |
| `process_resident_memory_bytes` | Gauge | > 200 MB → memory leak |

Prometheus scrapes `/metrics` on a 15-second interval. Grafana dashboards
visualise request rate (RPS), error rate, and latency percentiles (p50,
p95, p99). Alertmanager routes alerts to PagerDuty (P1 — service down)
and Slack (P3 — elevated error rate).

#### Distributed tracing

OpenTelemetry is instrumented at the FastAPI middleware layer. Traces are
exported to Jaeger or AWS X-Ray. A single `trace_id` links the Nginx
access log entry, the FastAPI span, and the MD5 computation span — making
latency attribution unambiguous.

---

### 6.3 Secrets Management

#### What must never be in plaintext

- Database credentials (if persistence is added)
- Registry pull secrets
- API keys for downstream services
- TLS private keys

#### Current state risk

`.env` files on developer machines. Acceptable for local development with
`.env` in `.gitignore`. Unacceptable in production.

#### Production pattern: Vault or cloud-native secrets

**HashiCorp Vault (self-hosted or HCP):**
The application authenticates to Vault using Kubernetes Service Account
tokens (Vault Kubernetes Auth Method). Secrets are injected as environment
variables by the Vault Agent Sidecar, never written to disk or baked into
the image.

```
Pod starts
  └── Vault Agent init container authenticates with SA token
  └── Vault Agent writes secret to shared in-memory volume (/vault/secrets/)
  └── App container reads secret at startup
  └── Vault Agent renews lease — app never sees an expired secret
```

**AWS Secrets Manager (cloud-native):**
Secrets are stored in AWS Secrets Manager. The EKS pod's IAM Role
(via IRSA — IAM Roles for Service Accounts) grants `secretsmanager:GetSecretValue`
permission. The application uses the AWS SDK at startup to fetch secrets
into memory. No secret ever appears in a manifest, environment file, or
CI log.

In both patterns, CI/CD pipelines access secrets through GitHub Actions
Secrets (for CI credentials) or OIDC federation (for cloud deployments),
never through hardcoded values.

---

### 6.4 High Availability & Scalability

#### Single-replica risk

The current Compose deployment runs one instance of each service. A
container crash, a node failure, or a deployment causes downtime. This
is the highest operational risk for a production service.

#### Kubernetes Horizontal Pod Autoscaler

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: logistics-api-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: logistics-api
  minReplicas: 3        # Minimum for HA across 3 availability zones
  maxReplicas: 20       # Maximum before upstream capacity review
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60   # Scale out when average CPU exceeds 60%
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "500"      # Scale out when RPS/pod exceeds 500
```

Three replicas are the minimum for genuine high availability: one pod can
be unavailable (during a rolling update or a node failure) while the
remaining two continue to serve traffic, and the third prevents
over-saturation during failover.

The Nginx layer is replaced by a **Kubernetes Ingress** controller
(NGINX Ingress or AWS ALB Ingress) that handles TLS termination,
path-based routing, rate limiting, and load distribution across all
healthy pod replicas.

Resource `requests` and `limits` are always set. Requests guarantee
the pod is scheduled on a node with sufficient capacity. Limits prevent
a runaway pod from starving neighbours. For this API, recommended
production sizing is `100m/64Mi` (requests) and `500m/256Mi` (limits)
per pod, validated against load test results.

---

### 6.5 Security

#### Container image scanning

The CI pipeline integrates **Trivy** (by Aqua Security) as a mandatory
build gate. Trivy scans the final `runner` image for known CVEs in OS
packages and Python dependencies:

```yaml
# In .github/workflows/ci.yml — runs after docker-build
- name: Scan image for vulnerabilities (Trivy)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: logistics-api:ci
    format: sarif
    output: trivy-results.sarif
    severity: HIGH,CRITICAL  # Fail the build on HIGH or CRITICAL CVEs
    exit-code: '1'

- name: Upload Trivy results to GitHub Security tab
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: trivy-results.sarif
```

Results appear in the GitHub Security tab as code-scanning alerts,
providing a permanent audit trail. `HIGH` and `CRITICAL` findings block
the pipeline until patched or explicitly accepted with a documented
exception.

**Grype** (by Anchore) is an alternative scanner with a complementary
vulnerability database — running both catches findings that either
database may be missing.

#### Network security layers before Nginx

In a cloud environment, traffic passes through multiple security layers
before reaching the Nginx container:

```
Internet
    │
    ▼
[Cloud WAF]          — AWS WAF / Cloudflare WAF
    │                  OWASP rule sets, IP reputation blocking,
    │                  rate limiting per IP, bot detection
    ▼
[DDoS Protection]    — AWS Shield Standard (automatic) / Shield Advanced
    │
    ▼
[Cloud Load Balancer]— AWS ALB / GCP Load Balancer
    │                  TLS termination, certificate management (ACM)
    │
    ▼
[Kubernetes Ingress] — NGINX Ingress Controller
    │                  Path routing, auth annotations, rate limiting
    │
    ▼
[Pod: api container] — FastAPI/Uvicorn
                       Non-root, read-only filesystem
```

**Additional security controls at the application layer:**

- **Network Policies** (Kubernetes): restrict pod-to-pod traffic so only the Ingress controller can reach the `api` pods
- **Pod Security Standards**: `restricted` profile enforces non-root UID, no privilege escalation, read-only root filesystem, and dropped capabilities
- **RBAC**: the application's ServiceAccount has zero Kubernetes API permissions (least privilege)
- **Dependency scanning**: Dependabot or Renovate automatically opens PRs when pinned dependencies have published newer versions with security patches

#### Rate limiting

The current Nginx configuration enforces payload size limits but no
request-rate limits. In production, `limit_req_zone` is added:

```nginx
# nginx.conf
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/m;

# conf.d/api.conf
location /validate-md5 {
    limit_req zone=api_limit burst=20 nodelay;
    # ... proxy_pass
}
```

100 requests per minute per IP with a burst allowance of 20 prevents
brute-force flooding of the validation endpoint. In Kubernetes, this is
complemented by the Ingress controller's annotation-based rate limiting
and the WAF's per-IP request tracking.

---

### 6.6 Assumptions

| Assumption | Impact if incorrect |
|---|---|
| MD5 is used as an integrity fingerprint, not as a cryptographic authentication primitive. Clients are trusted to compute the hash correctly. | If adversarial clients exist, replace MD5 with HMAC-SHA256 using a shared secret. MD5 is not collision-resistant enough for security-sensitive use cases. |
| The `payload` field contains only JSON-serialisable types (strings, numbers, booleans, nested objects/arrays). | Introduce explicit type restrictions in the Pydantic schema and document them if the payload schema is known in advance. |
| `DOCS_ENABLED=true` is acceptable in this environment. | Set `DOCS_ENABLED=false` in production to hide `/docs`, `/redoc`, and `/openapi.json` from unauthenticated users, or protect them behind an auth middleware. |
| Single-region deployment is sufficient for this challenge. | Multi-region deployments require a global load balancer, cross-region registry replication, and distributed health monitoring. |

---

## 7. Tech Stack

| Component | Technology | Version |
|---|---|---|
| API framework | FastAPI | 0.115.5 |
| ASGI server | Uvicorn (standard) | 0.32.1 |
| Data validation | Pydantic v2 | bundled with FastAPI |
| Settings | pydantic-settings | 2.6.1 |
| Runtime | Python | 3.12 (slim) |
| Reverse proxy | Nginx | 1.27-alpine |
| Orchestration | Docker Compose | v2 plugin |
| Linter | Ruff | 0.7.4 |
| Test framework | pytest | 8.3.3 |
| CI | GitHub Actions | ubuntu-latest |
| Image scanner | Trivy | aquasecurity/trivy-action |

---

<details>
<summary>Running tests locally</summary>

```bash
# Install dependencies (consider a virtualenv)
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pip install pytest-cov ruff

# Lint
ruff check app/ tests/
ruff format app/ tests/ --check

# Tests with coverage
pytest tests/ -v --cov=app --cov-report=term-missing
```

</details>

<details>
<summary>Computing the canonical MD5 in other languages</summary>

**Node.js**
```javascript
const crypto = require('crypto');
const payload = { status: 'shipped', order_id: 42 };
const sorted = Object.keys(payload).sort().reduce((o, k) => ({ ...o, [k]: payload[k] }), {});
const canonical = JSON.stringify(sorted);   // '{"order_id":42,"status":"shipped"}'
const md5 = crypto.createHash('md5').update(canonical, 'utf8').digest('hex');
```

**Go**
```go
import ("crypto/md5"; "encoding/json"; "fmt"; "sort")

payload := map[string]any{"status": "shipped", "order_id": 42}
keys := make([]string, 0, len(payload))
for k := range payload { keys = append(keys, k) }
sort.Strings(keys)
// Use json.Marshal on a sorted structure or a custom encoder
canonical, _ := json.Marshal(payload)  // Go's encoding/json sorts map keys
hash := md5.Sum(canonical)
fmt.Printf("%x\n", hash)
```

**Java**
```java
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
// Jackson sorts keys with SORT_PROPERTIES_ALPHABETICALLY
ObjectMapper mapper = new ObjectMapper()
    .configure(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS, true);
String canonical = mapper.writeValueAsString(payload);
// Then MD5 the canonical string with MessageDigest
```

</details>

---

## 8. Known Troubleshooting

This section documents bugs found and resolved during the first local startup
of the stack. Recorded as reference for future contributors or similar environments.

---

### 8.1 `scripts/healthcheck.sh` — Syntax error at line 44

**Symptom**

```
./scripts/healthcheck.sh: line 44: syntax error near unexpected token ')'
```

**Root cause**

In Bash, functions are called inside `$(...)` **without parentheses**.
The original code used `$(timestamp())`, which mixes the function *definition*
syntax with the *invocation* syntax, causing a parse error:

```bash
# ❌ Invalid syntax — the parser interprets this as a definition
log_up() { echo "[$(timestamp())] ..."; }

# ✅ Correct — invocation without empty parentheses
log_up() { echo "[$(timestamp)] ..."; }
```

**Affected files**

- [`scripts/healthcheck.sh`](scripts/healthcheck.sh) — lines 44, 45 and 46
  (functions `log_up`, `log_down` and `log_info`)

**Fix applied**

Removed the empty parentheses from all three `timestamp` calls inside the
command substitutions. Verified with `bash -n scripts/healthcheck.sh`.

---

### 8.2 Nginx returns 404 instead of proxying to FastAPI

**Symptom**

Containers start, `logistics_api` shows as `Healthy`, but
`curl http://localhost/health` returns an Nginx HTML 404 page instead of
the JSON `{"status":"ok"}`.

```
< HTTP/1.1 404 Not Found
< Server: nginx
<html><body><h1>404 Not Found</h1></body></html>
```

**Root cause**

The official `nginx:1.27-alpine` image ships a pre-installed file at
`/etc/nginx/conf.d/default.conf`. That file defines a `server { listen 80; ... }`
catch-all block. By mounting only our `api.conf` into the same directory,
Nginx loads **both** server blocks on port 80:

```
/etc/nginx/conf.d/
├── api.conf       ← our reverse proxy (mounted via volume)
└── default.conf   ← shipped with the base image (serves static files)
```

When two `server` blocks share the same port without distinct `server_name`
values, Nginx may resolve to `default.conf` instead of ours, returning 404
because there are no static files to serve.

**Fix applied**

Added a `command` directive to the `nginx` service in
[`docker-compose.yml`](docker-compose.yml) that removes `default.conf`
before starting the nginx process:

```yaml
# docker-compose.yml — nginx service
command: >
  /bin/sh -c "rm -f /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"
```

This guarantees that the only active server block is the one in `api.conf`,
regardless of the base image version in use.

**Verification**

```bash
# Confirm that default.conf was removed from the running container
docker exec logistics_nginx ls /etc/nginx/conf.d/
# Expected output: api.conf

# Confirm that the proxy responds correctly
curl http://localhost/health
# Expected output: {"status":"ok","version":"1.0.0"}
```

---

*Logistics Validation API · DevSecOps Technical Challenge*
