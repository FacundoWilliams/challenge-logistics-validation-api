# Logistics Validation API

> API REST para validación de integridad de payloads mediante hashing MD5 canónico.
> Construida con FastAPI · Uvicorn · Nginx · Docker · GitHub Actions.

[![CI](https://github.com/<org>/logistics-api-challenge/actions/workflows/ci.yml/badge.svg)](https://github.com/<org>/logistics-api-challenge/actions/workflows/ci.yml)
![Python](https://img.shields.io/badge/Python-3.12-blue?logo=python)
![FastAPI](https://img.shields.io/badge/FastAPI-0.115.5-009688?logo=fastapi)
![Docker](https://img.shields.io/badge/Docker-multistage-2496ED?logo=docker)
![License](https://img.shields.io/badge/Licencia-Privada-lightgrey)

---

## Tabla de contenidos

1. [Quick Start](#1-quick-start)
2. [Referencia de endpoints](#2-referencia-de-endpoints)
3. [Decisiones técnicas y arquitectura](#3-decisiones-técnicas-y-arquitectura)
4. [Pipeline de CI/CD](#4-pipeline-de-cicd)
5. [Referencia de scripts](#5-referencia-de-scripts)
6. [Riesgos, supuestos y hoja de ruta a producción](#6-riesgos-supuestos-y-hoja-de-ruta-a-producción)
7. [Tech stack](#7-tech-stack)
8. [Troubleshooting conocido](#8-troubleshooting-conocido)
9. [Entorno de Ejecución](#9-entorno-de-ejecución)
10. [Desarrollo Local y Formateo](#10-desarrollo-local-y-formateo)

---

## 1. Quick Start

### Requisitos previos

| Herramienta | Versión mínima | Propósito |
|---|---|---|
| Docker Engine | 24.x | Container runtime |
| Docker Compose | v2 plugin | Orquestación del stack |
| Bash | 4.x | Scripts de automatización |
| curl | cualquiera | Testing manual y healthcheck |
| Python | 3.12 | Ejecución de tests locales (opcional) |

### 1.1 Clonar y configurar

```bash
git clone https://github.com/<org>/logistics-api-challenge.git
cd logistics-api-challenge

# Copiar la plantilla de entorno — editar los valores según sea necesario
cp .env.example .env
```

### 1.2 Construir la imagen Docker

```bash
./scripts/build.sh
```

Este comando construye la imagen multistage y aplica dos tags: `logistics-api:local`
(alias estable para desarrollo) y `logistics-api:<git-sha>` (trazabilidad del commit).
Pasar `--no-cache` para un build completamente limpio:

```bash
./scripts/build.sh --no-cache
```

### 1.3 Levantar el stack completo

```bash
./scripts/start.sh
```

El script levanta ambos servicios en modo detached y hace polling contra
`http://localhost/health` (a través de Nginx) hasta que el stack esté listo.
Cuando imprime el banner de confirmación, ambos containers están healthy.

```
[2025-01-15 10:00:01] [OK] =============================================
[2025-01-15 10:00:01] [OK]  Stack is UP and healthy!
[2025-01-15 10:00:01] [OK] =============================================
[2025-01-15 10:00:01] [OK]   API (via Nginx) : http://localhost/health
[2025-01-15 10:00:01] [OK]   Swagger UI      : http://localhost/docs
```

### 1.4 Explorar el Swagger UI

```
http://localhost/docs          # Swagger UI — explorador interactivo de la API
http://localhost/redoc         # ReDoc — vista alternativa de documentación
http://localhost/openapi.json  # Schema OpenAPI 3.1 en crudo
```

---

## 2. Referencia de endpoints

### 2.1 `GET /health`

Liveness probe. Devuelve `200 OK` cuando el servicio está en ejecución.

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

Valida que un digest MD5 hexadecimal provisto coincida con la representación
JSON canónica de un payload dado.

#### Schema del request body

| Campo | Tipo | Requerido | Descripción |
|---|---|---|---|
| `payload` | `object` | Sí | Cualquier objeto JSON cuya integridad será validada |
| `md5_hash` | `string` | Sí | Digest MD5 hexadecimal en minúsculas de 32 caracteres |

`md5_hash` es validado por Pydantic antes de que se ejecute cualquier lógica de negocio.
Caracteres no hexadecimales o longitud incorrecta devuelven `422` de forma inmediata.

---

#### Caso 1 — Válido: el hash coincide con el payload

Primero, computar el MD5 canónico del payload localmente:

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

Luego enviarlo con POST (nota: el orden de las keys en el request **no importa** — el servidor canonicaliza antes de hashear):

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

La respuesta incluye `canonical_json` — el string UTF-8 exacto que fue procesado
por la función MD5 — habilitando auditabilidad completa del lado del cliente.

---

#### Caso 2 — Inválido: el hash no coincide con el payload

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

#### Caso 3 — Malformado: `md5_hash` tiene formato incorrecto

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

HTTP status: **422 Unprocessable Entity** (Pydantic rechaza el campo antes de que se ejecute cualquier lógica de negocio)

---

#### Caso 4 — Monitoreo continuo de salud

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

#### Detener el stack

```bash
./scripts/stop.sh               # Detiene y elimina containers + red
./scripts/stop.sh --volumes     # También elimina los named volumes
./scripts/stop.sh --rmi         # También elimina las imágenes construidas
```

---

## 3. Decisiones técnicas y arquitectura

### 3.1 ¿Por qué FastAPI?

FastAPI fue elegido sobre Flask, Django REST Framework y otras alternativas Python
en base a cuatro ventajas concretas de ingeniería:

**Generación nativa de OpenAPI 3.1 sin configuración adicional.**
El Swagger UI en `/docs` y el schema en `/openapi.json` se generan automáticamente
a partir de los type hints de Python y los modelos Pydantic. No existe un archivo de
documentación separado que mantener y no hay riesgo de que la documentación diverja
de la implementación.

**Validación con Pydantic v2 en el boundary.**
Cada campo del request es parseado y validado antes de que se ejecute cualquier código
de aplicación. El campo `md5_hash` es rechazado con un error 422 estructurado si no
es una cadena hexadecimal de 32 caracteres — sin necesidad de código de validación
escrito a mano. Esto desplaza la validación hacia la izquierda del pipeline y mantiene
la capa de routers delgada.

**Diseño async-nativo y moderno.**
FastAPI está construido sobre Starlette y corre sobre el servidor ASGI de Uvicorn.
Aunque el cómputo del MD5 es sincrónico, la arquitectura está preparada para llamadas
asíncronas a bases de datos, requests HTTP salientes o tareas en background sin necesidad
de una reescritura.

**Defaults listos para producción.**
Límites de tamaño del request body, serialización automática de errores 422, exception
handlers estructurados y CORS middleware son features de primera clase, no plugins de terceros.

---

### 3.2 Topología de red

```
                    ┌─────────────────────────────────┐
  Internet / Host   │   Docker bridge: logistics_net  │
                    │                                  │
  :80 ──────────► [nginx:80]                          │
                    │   proxy_pass http://api:8000     │
                    │         ↓                        │
                    │     [api:8000]  ← NO publicado   │
                    │   FastAPI/Uvicorn                │
                    └─────────────────────────────────┘
```

El puerto `8000` está declarado con `expose:` en `docker-compose.yml`, no con `ports:`.
Esto lo hace alcanzable únicamente dentro de `logistics_net`. El host y el exterior
solo pueden acceder a la aplicación a través de Nginx en el puerto `80`. Esto garantiza
que todos los security headers, controles de timeout y límites de tamaño de payload
que enforcea Nginx no puedan ser bypasseados.

---

### 3.3 El problema del MD5 canónico

#### Por qué el hashing ingenuo falla

JSON (RFC 8259) no impone un orden de keys en los objetos. Dos llamadas a un
serializador JSON desde lenguajes distintos — o incluso versiones distintas de la
misma librería — pueden producir secuencias de bytes diferentes para objetos
semánticamente idénticos:

```
{"a": 1, "b": 2}   →   MD5: d0a5a7f3...
{"b": 2, "a": 1}   →   MD5: 9e107d9d...   ← hash distinto, misma data
```

Cualquier esquema de hashing que opere sobre bytes JSON crudos es, por lo tanto,
**no determinístico** entre clientes. El servidor y el cliente computarán hashes
distintos para el mismo payload lógico a menos que acuerden una forma de serialización
exacta.

#### La forma canónica

La solución define un único contrato de serialización sin ambigüedad:

```python
import hashlib, json

def compute_md5(payload: dict) -> tuple[str, str]:
    canonical = json.dumps(
        payload,
        sort_keys=True,        # Regla 1 — orden lexicográfico de keys
        separators=(',', ':'), # Regla 2 — sin espacios entre tokens
        ensure_ascii=True,     # Regla 3 — no-ASCII → escapes \uXXXX
    )
    digest = hashlib.md5(canonical.encode('utf-8')).hexdigest()
    return digest, canonical
```

| Regla | Parámetro | Valor | Justificación |
|---|---|---|---|
| Orden de keys | `sort_keys` | `True` | Orden lexicográfico elimina la dependencia del orden de inserción en todos los clientes y lenguajes |
| Separadores | `separators` | `(',', ':')` | Sin espacios elimina la ambigüedad entre la forma compacta `{"a":1}` y la pretty-printed `{"a": 1}` |
| Encoding de chars | `ensure_ascii` | `True` | Los caracteres no-ASCII se serializan como secuencias de escape `\uXXXX`, previniendo divergencia entre sistemas con distintos codecs de locale |
| Encoding de bytes | `.encode()` | `'utf-8'` | UTF-8 es la representación a nivel de bytes sin ambigüedad; necesaria antes de cualquier función de hashing |
| Campo excluido | `md5_hash` | omitido | Hashear el hash sería circular — solo `payload` se canonicaliza |

Este enfoque refleja la intención del JSON Canonicalization Scheme (JCS, RFC 8785)
sin introducir una dependencia externa, y es completamente reproducible en cualquier
lenguaje con una librería JSON estándar:

```python
# Python
json.dumps(payload, sort_keys=True, separators=(',', ':'))

# Node.js
JSON.stringify(Object.keys(payload).sort().reduce((o, k) => ({ ...o, [k]: payload[k] }), {}))

# Go
// encoding/json hace marshal de los campos de struct en orden de declaración;
// usar un map con keys ordenadas o un marshaller customizado
```

#### Por qué 422 y no 400 en caso de mismatch del hash

HTTP 400 Bad Request señala un mensaje malformado o no parseable.
HTTP 422 Unprocessable Entity (RFC 9110 §15.5.21) señala que el request es
sintácticamente válido pero semánticamente incorrecto. Un mismatch del hash es
un fallo de integridad semántica — el JSON se parseó correctamente, pero el
fingerprint declarado no coincide con el fingerprint computado. Usar 422 es
consistente con la forma en que FastAPI señala sus propios errores de validación
y comunica claramente la naturaleza del error a los consumidores de la API.

---

### 3.4 Dockerfile: build multistage

```dockerfile
# Stage 1 — builder: instala dependencias en el prefijo /install
FROM python:3.12-slim AS builder
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2 — runner: copia solo los artefactos de wheels + source
FROM python:3.12-slim AS runner
COPY --from=builder /install /usr/local
COPY app/ ./app/
```

El stage `builder` contiene pip, setuptools, wheel y cualquier compilador nativo.
Ninguno de estos llega a la imagen final. La imagen `runner` incluye únicamente
los paquetes instalados y el código fuente de la aplicación.

Hardening de seguridad en el stage runner:

- `apt-get upgrade -y` en build time — parchea CVEs conocidos en la imagen base
- Usuario no-root (`appuser`, sin shell, sin home directory) — limita el blast radius ante un container escape
- `HEALTHCHECK` via stdlib `urllib.request` — sin dependencia en runtime de `curl`
- `.dockerignore` excluye `.git`, `tests/`, `__pycache__`, `.env` y todos los artefactos de desarrollo

---

### 3.5 Directivas de seguridad de Nginx

| Directiva | Valor | Riesgo mitigado |
|---|---|---|
| `server_tokens` | `off` | Oculta la versión de Nginx en páginas de error y el header `Server` |
| `X-Content-Type-Options` | `nosniff` | Previene ataques de MIME-sniffing |
| `X-Frame-Options` | `DENY` | Bloquea clickjacking mediante embedding en iframes |
| `X-XSS-Protection` | `1; mode=block` | Filtro XSS para navegadores legacy |
| `Cache-Control` | `no-store` | Previene el cacheo de datos sensibles de respuesta |
| `client_max_body_size` | `512k` | Rechaza bodies sobredimensionados en la capa del proxy (mitigación de DoS) |
| `proxy_connect_timeout` | `5s` | Limita el agotamiento lento de conexiones TCP |
| `proxy_read_timeout` | `30s` | Limita ataques de tipo slow-read / Slowloris |
| `location ~ /\.` | `deny all` | Bloquea acceso a dot-files (`.git`, `.env`) |
| `keepalive` | `32` | Reutiliza conexiones TCP hacia el upstream (performance) |

Todos los security headers usan el flag `always` para que sean añadidos también
a las respuestas `4xx` y `5xx`, no solo a las `2xx`.

---

## 4. Pipeline de CI/CD

### Visión general del pipeline

```
push / pull_request
        │
        ▼
┌──────────────────┐     falla → detiene
│  lint-and-test   │ ──────────────────────────────►  ✗
│  Ruff + pytest   │
└──────────┬───────┘
           │ pasa
           ▼
┌──────────────────┐     falla → detiene
│  docker-build    │ ──────────────────────────────►  ✗
│  BuildX + cache  │
└──────────┬───────┘
           │ pasa
           ▼
┌──────────────────┐
│  integration     │
│  Compose up      │
│  curl /health    │
│  curl /validate  │
│  Compose down    │
└──────────────────┘
```

### Detalle de cada stage

**`lint-and-test`** — se ejecuta en cada push y PR, sin Docker.
Instala dependencias desde el pip cache, ejecuta Ruff para detección de
estilo y bugs con `--output-format=github` (renderiza anotaciones inline en el diff
del PR), y corre pytest con coverage. El coverage se sube como artefact del build
y se retiene por 14 días.

**`docker-build`** — se ejecuta solo tras pasar los tests. Usa
`docker/build-push-action` con el backend de cache de GitHub Actions
(`type=local`). La cache key se computa a partir del hash de `requirements.txt`
y `Dockerfile`, por lo que se invalida precisamente cuando cambian las dependencias
o los pasos de build. El "cache dance" (`/tmp/.buildx-cache-new` → rename →
`/tmp/.buildx-cache`) previene el crecimiento ilimitado de la caché entre runs.
El tamaño de la imagen se reporta en el job summary.

**`integration`** — ejecuta el stack Compose completo en el runner de GitHub
y valida el sistema en vivo:

1. Hace polling de `docker inspect --format='{{.State.Health.Status}}'` hasta que el container `api` está `healthy`
2. Envía `GET http://localhost/health` a través de Nginx, verifica `HTTP 200` y `"status": "ok"` en el body
3. Computa el MD5 canónico inline con Python, envía `POST http://localhost/validate-md5`, verifica `HTTP 200`
4. Detiene el stack incondicionalmente (`if: always()`)
5. Escribe una tabla de resultados en `$GITHUB_STEP_SUMMARY`

### Control de concurrencia

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

Un nuevo push al mismo branch cancela inmediatamente cualquier run en curso,
previniendo acumulación en la cola y desperdicio de minutos del runner.

---

## 5. Referencia de scripts

Todos los scripts usan `set -euo pipefail`:
- `-e` sale inmediatamente ante cualquier código de retorno distinto de cero
- `-u` trata las variables no definidas como errores
- `-o pipefail` propaga fallos a través de pipes

| Script | Opciones principales | Descripción |
|---|---|---|
| `build.sh` | `--no-cache` | Construye `logistics-api:local` y `logistics-api:<git-sha>`. Reporta el tamaño final de la imagen. |
| `start.sh` | `--build`, `--env-file <path>` | Levanta el stack Compose en modo detached. Hace polling de `/health` via Nginx hasta que esté listo. Imprime la URL de Swagger al finalizar. |
| `stop.sh` | `--volumes`, `--rmi` | Detiene los containers y elimina la red. `--volumes` borra los datos. `--rmi` elimina las imágenes (fuerza rebuild completo). |
| `healthcheck.sh` | `--url <url>`, `--interval <s>` | Loop infinito. Hace polling de `/health` cada 5 s. Imprime `UP`/`DOWN` con timestamp y contador de fallos consecutivos. Los colores ANSI se deshabilitan automáticamente en entornos no-TTY (logs de CI, pipes). |

---

## 6. Riesgos, supuestos y hoja de ruta a producción

Esta sección aborda la brecha conceptual y arquitectónica entre la implementación
actual de desarrollo local y un despliegue de producción endurecido y a gran escala.
Cada subsección mapea un riesgo conocido a su mitigación estándar de la industria.

---

### 6.1 Deployment, versionado y rollbacks

#### Estado actual
Docker Compose con una sola réplica por servicio. Útil para desarrollo local y
validación en CI. No adecuado para deployments en producción sin downtime.

#### Target de producción: Kubernetes

Las imágenes de container se tagean con el Git SHA en build time
(`logistics-api:a3f9c1b`). Este tag es inmutable — un tag dado siempre hace
referencia al mismo build. El pipeline de CI hace push hacia un **registry privado**
(AWS ECR, Google Artifact Registry o GitHub Container Registry con controles de
acceso). Los registries públicos no se usan en producción porque exponen metadata
de las imágenes y no tienen audit trail de acceso.

**Estrategia de deployment — Blue/Green para este servicio:**

Blue/Green es apropiado para una API stateless sin migraciones de schema.
Se mantienen dos entornos idénticos (Blue = actual, Green = siguiente).
El tráfico se cambia a nivel del load balancer una vez que el entorno Green supera
sus gates de salud. El rollback es instantáneo — cambiar el load balancer de vuelta
a Blue. No se requieren reinicios de pods.

```
Load Balancer
    │
    ├── Blue  (v1.2.0 — 100% del tráfico, activo)
    └── Green (v1.3.0 — 0% del tráfico, siendo validado)

Tras superar la validación:
    ├── Blue  (v1.2.0 — 0% del tráfico, standby para rollback)
    └── Green (v1.3.0 — 100% del tráfico, activo)
```

**Alternativa — Canary para confianza gradual:**

Si el cambio implica mayor riesgo (p.ej., un cambio en el algoritmo de
canonicalización), un deployment Canary desplaza el tráfico de forma incremental:
1% → 5% → 25% → 100%, con rollback automático si la tasa de errores o la latencia
p99 superan los umbrales definidos en Prometheus.

**Patrón del manifiesto Kubernetes:**

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
      maxUnavailable: 0     # Nunca reducir capacidad durante el rollout
      maxSurge: 1           # Levantar un pod nuevo antes de bajar uno
  selector:
    matchLabels:
      app: logistics-api
  template:
    metadata:
      labels:
        app: logistics-api
        version: "a3f9c1b"  # Git SHA como label para trazabilidad
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

### 6.2 Observabilidad

#### Logs

En producción, el formato de log de texto plano de Uvicorn se reemplaza por
**logging estructurado en JSON**. Cada línea de log es un objeto JSON parseable
con campos consistentes:

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

Un `request_id` (UUID generado por request o propagado desde un header upstream
`X-Request-ID`) permite trazar una transacción única a través de los access logs
de Nginx, los logs de aplicación de FastAPI y cualquier servicio downstream.
Los logs se envían a un sistema centralizado de agregación (AWS CloudWatch Logs,
Google Cloud Logging, o un stack Loki self-hosted) y se retienen según la política
de compliance.

#### Métricas

La aplicación expone un endpoint `/metrics` (mediante la librería
`prometheus-fastapi-instrumentator`) con los siguientes indicadores clave:

| Métrica | Tipo | Condición de alerta |
|---|---|---|
| `http_requests_total` | Counter | Spike repentino → posible abuso |
| `http_request_duration_seconds` | Histogram | p99 > 500 ms → breach de SLA |
| `http_requests_errors_total` | Counter | Tasa de 5xx > 1% → alerta inmediata |
| `process_resident_memory_bytes` | Gauge | > 200 MB → memory leak |

Prometheus scrapea `/metrics` en intervalos de 15 segundos. Los dashboards de Grafana
visualizan request rate (RPS), tasa de errores y percentiles de latencia (p50, p95, p99).
Alertmanager enruta las alertas a PagerDuty (P1 — servicio caído) y Slack
(P3 — tasa de errores elevada).

#### Distributed tracing

OpenTelemetry se instrumenta a nivel del middleware de FastAPI. Los traces se exportan
a Jaeger o AWS X-Ray. Un único `trace_id` vincula la entrada en el access log de Nginx,
el span de FastAPI y el span de cómputo del MD5 — haciendo la atribución de latencia
inequívoca.

---

### 6.3 Gestión de secrets

#### Qué nunca debe estar en texto plano

- Credenciales de bases de datos (si se añade persistencia)
- Pull secrets del registry
- API keys para servicios downstream
- Claves privadas TLS

#### Riesgo del estado actual

Archivos `.env` en las máquinas de los desarrolladores. Aceptable para desarrollo
local con `.env` en `.gitignore`. Inaceptable en producción.

#### Patrón de producción: Vault o cloud-native secrets

**HashiCorp Vault (self-hosted o HCP):**
La aplicación se autentica en Vault usando tokens de Service Account de Kubernetes
(Vault Kubernetes Auth Method). Los secrets se inyectan como variables de entorno
por el Vault Agent Sidecar, nunca se escriben en disco ni se baquean en la imagen.

```
El Pod arranca
  └── Init container de Vault Agent se autentica con el token del SA
  └── Vault Agent escribe el secret en un volumen in-memory compartido (/vault/secrets/)
  └── El container de la aplicación lee el secret al iniciar
  └── Vault Agent renueva el lease — la aplicación nunca ve un secret expirado
```

**AWS Secrets Manager (cloud-native):**
Los secrets se almacenan en AWS Secrets Manager. El IAM Role del pod en EKS
(vía IRSA — IAM Roles for Service Accounts) otorga permiso de `secretsmanager:GetSecretValue`.
La aplicación usa el AWS SDK al arrancar para traer los secrets a memoria.
Ningún secret aparece jamás en un manifiesto, archivo de entorno o log de CI.

En ambos patrones, los pipelines de CI/CD acceden a los secrets a través de
GitHub Actions Secrets (para credenciales de CI) o federación OIDC (para deployments
en cloud), nunca mediante valores hardcodeados.

---

### 6.4 Alta disponibilidad y escalabilidad

#### Riesgo de réplica única

El deployment actual con Compose corre una instancia de cada servicio. Un crash del
container, un fallo de nodo o un deployment provocan downtime. Este es el riesgo
operacional más alto para un servicio en producción.

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
  minReplicas: 3        # Mínimo para HA en 3 zonas de disponibilidad
  maxReplicas: 20       # Máximo antes de una revisión de capacidad upstream
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60   # Scale out cuando el CPU promedio supera el 60%
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "500"      # Scale out cuando el RPS/pod supera los 500
```

Tres réplicas son el mínimo para alta disponibilidad genuina: un pod puede estar
no disponible (durante un rolling update o un fallo de nodo) mientras los dos
restantes continúan sirviendo tráfico, y el tercero previene la sobresaturación
durante el failover.

La capa de Nginx se reemplaza por un **Kubernetes Ingress** controller
(NGINX Ingress o AWS ALB Ingress) que gestiona la terminación TLS, el routing por
paths, el rate limiting y la distribución de carga entre todas las réplicas de pods
healthy.

Los `requests` y `limits` de recursos siempre se configuran. Los requests garantizan
que el pod sea schedulado en un nodo con capacidad suficiente. Los limits previenen
que un pod en fuga consuma los recursos de sus vecinos. Para esta API, el sizing
recomendado en producción es `100m/64Mi` (requests) y `500m/256Mi` (limits) por pod,
validado contra los resultados de los load tests.

---

### 6.5 Seguridad

#### Escaneo de imágenes de container

El pipeline de CI integra **Trivy** (de Aqua Security) como gate obligatorio de build.
Trivy escanea la imagen final `runner` en busca de CVEs conocidos en paquetes del SO
y dependencias Python:

```yaml
# En .github/workflows/ci.yml — se ejecuta tras docker-build
- name: Escanear imagen en busca de vulnerabilidades (Trivy)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: logistics-api:ci
    format: sarif
    output: trivy-results.sarif
    severity: HIGH,CRITICAL  # Falla el build ante CVEs HIGH o CRITICAL
    exit-code: '1'

- name: Subir resultados de Trivy al tab de Security de GitHub
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: trivy-results.sarif
```

Los resultados aparecen en el tab de Security de GitHub como alertas de
code-scanning, proveyendo un audit trail permanente. Los hallazgos `HIGH` y
`CRITICAL` bloquean el pipeline hasta que son parchados o explícitamente aceptados
con una excepción documentada.

**Grype** (de Anchore) es un scanner alternativo con una base de datos de
vulnerabilidades complementaria — correr ambos captura hallazgos que cualquiera de
las dos bases de datos podría estar omitiendo.

#### Capas de seguridad de red previas a Nginx

En un entorno cloud, el tráfico atraviesa múltiples capas de seguridad antes de
llegar al container Nginx:

```
Internet
    │
    ▼
[Cloud WAF]             — AWS WAF / Cloudflare WAF
    │                     Reglas OWASP, bloqueo por reputación de IP,
    │                     rate limiting por IP, detección de bots
    ▼
[Protección DDoS]       — AWS Shield Standard (automático) / Shield Advanced
    │
    ▼
[Cloud Load Balancer]   — AWS ALB / GCP Load Balancer
    │                     Terminación TLS, gestión de certificados (ACM)
    │
    ▼
[Kubernetes Ingress]    — NGINX Ingress Controller
    │                     Path routing, anotaciones de auth, rate limiting
    │
    ▼
[Pod: api container]    — FastAPI/Uvicorn
                          No-root, filesystem de solo lectura
```

**Controles de seguridad adicionales en la capa de aplicación:**

- **Network Policies** (Kubernetes): restringen el tráfico pod-a-pod para que solo el Ingress controller pueda alcanzar los pods `api`
- **Pod Security Standards**: el perfil `restricted` enforcea UID no-root, sin escalada de privilegios, filesystem raíz de solo lectura y capabilities eliminadas
- **RBAC**: el ServiceAccount de la aplicación tiene cero permisos sobre la API de Kubernetes (least privilege)
- **Dependency scanning**: Dependabot o Renovate abren PRs automáticamente cuando las dependencias pinadas tienen versiones nuevas publicadas con parches de seguridad

#### Rate limiting

La configuración actual de Nginx enforcea límites de tamaño de payload pero no
límites de tasa de requests. En producción, se añade `limit_req_zone`:

```nginx
# nginx.conf
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=100r/m;

# conf.d/api.conf
location /validate-md5 {
    limit_req zone=api_limit burst=20 nodelay;
    # ... proxy_pass
}
```

100 requests por minuto por IP con un allowance de burst de 20 previene el flood
de fuerza bruta del endpoint de validación. En Kubernetes, esto se complementa con
el rate limiting basado en anotaciones del Ingress controller y el tracking de
requests por IP del WAF.

---

### 6.6 Supuestos

| Supuesto | Impacto si es incorrecto |
|---|---|
| MD5 se usa como fingerprint de integridad, no como primitiva de autenticación criptográfica. Se confía en que los clientes computen el hash correctamente. | Si existen clientes adversariales, reemplazar MD5 con HMAC-SHA256 usando un shared secret. MD5 no es suficientemente resistente a colisiones para casos de uso sensibles a la seguridad. |
| El campo `payload` contiene únicamente tipos JSON-serializables (strings, números, booleanos, objetos/arrays anidados). | Introducir restricciones de tipo explícitas en el schema de Pydantic y documentarlas si el schema del payload es conocido de antemano. |
| `DOCS_ENABLED=true` es aceptable en este entorno. | Configurar `DOCS_ENABLED=false` en producción para ocultar `/docs`, `/redoc` y `/openapi.json` a usuarios no autenticados, o protegerlos detrás de un middleware de autenticación. |
| El deployment en una sola región es suficiente para este challenge. | Los deployments multi-región requieren un load balancer global, replicación de registry entre regiones y monitoreo de salud distribuido. |

---

## 7. Tech stack

| Componente | Tecnología | Versión |
|---|---|---|
| API framework | FastAPI | 0.115.5 |
| ASGI server | Uvicorn (standard) | 0.32.1 |
| Validación de datos | Pydantic v2 | bundled con FastAPI |
| Settings | pydantic-settings | 2.6.1 |
| Runtime | Python | 3.12 (slim) |
| Reverse proxy | Nginx | 1.27-alpine |
| Orquestación | Docker Compose | v2 plugin |
| Linter | Ruff | 0.7.4 |
| Test framework | pytest | 8.3.3 |
| CI | GitHub Actions | ubuntu-latest |
| Image scanner | Trivy | aquasecurity/trivy-action |

---

<details>
<summary>Ejecutar tests localmente</summary>

```bash
# Instalar dependencias (se recomienda un virtualenv)
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
pip install pytest-cov ruff

# Linter
ruff check app/ tests/
ruff format app/ tests/ --check

# Tests con coverage
pytest tests/ -v --cov=app --cov-report=term-missing
```

</details>

<details>
<summary>Calcular el MD5 canónico en otros lenguajes</summary>

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
// Usar json.Marshal sobre una estructura ordenada o un encoder customizado
canonical, _ := json.Marshal(payload)  // encoding/json de Go ordena las keys del map
hash := md5.Sum(canonical)
fmt.Printf("%x\n", hash)
```

**Java**
```java
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
// Jackson ordena las keys con SORT_PROPERTIES_ALPHABETICALLY
ObjectMapper mapper = new ObjectMapper()
    .configure(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS, true);
String canonical = mapper.writeValueAsString(payload);
// Luego calcular el MD5 del string canonical con MessageDigest
```

</details>

---

## 8. Troubleshooting conocido

Esta sección documenta los bugs encontrados y resueltos durante el primer
arranque del stack en desarrollo local. Se registran como referencia para
futuros contribuidores o entornos similares.

---

### 8.1 `scripts/healthcheck.sh` — Syntax error en línea 44

**Síntoma**

```
./scripts/healthcheck.sh: line 44: syntax error near unexpected token ')'
```

**Causa raíz**

En Bash, las funciones se invocan dentro de `$(...)` **sin paréntesis**.
El código original usaba `$(timestamp())`, que mezcla la sintaxis de
*definición* de función con la de *invocación*, produciendo un error de
parseo:

```bash
# ❌ Sintaxis inválida — el parser lo interpreta como definición
log_up() { echo "[$(timestamp())] ..."; }

# ✅ Correcto — invocación sin paréntesis vacíos
log_up() { echo "[$(timestamp)] ..."; }
```

**Archivos afectados**

- [`scripts/healthcheck.sh`](scripts/healthcheck.sh) — líneas 44, 45 y 46
  (funciones `log_up`, `log_down` y `log_info`)

**Fix aplicado**

Se eliminaron los paréntesis vacíos de las tres llamadas a `timestamp`
dentro de los command substitutions. Verificado con `bash -n scripts/healthcheck.sh`.

---

### 8.2 Nginx devuelve 404 en lugar de hacer proxy al FastAPI

**Síntoma**

Los contenedores arrancan, el container `logistics_api` aparece como
`Healthy`, pero `curl http://localhost/health` devuelve una página HTML
404 de Nginx en lugar del JSON `{"status":"ok"}`.

```
< HTTP/1.1 404 Not Found
< Server: nginx
<html><body><h1>404 Not Found</h1></body></html>
```

**Causa raíz**

La imagen oficial `nginx:1.27-alpine` incluye un archivo
`/etc/nginx/conf.d/default.conf` preinstalado. Este archivo define un
`server { listen 80; ... }` que actúa como catch-all. Al montar únicamente
nuestro `api.conf` en el mismo directorio, Nginx carga **ambos** server
blocks en el puerto 80:

```
/etc/nginx/conf.d/
├── api.conf       ← nuestro proxy (montado vía volume)
└── default.conf   ← incluido en la imagen base (servía contenido estático)
```

Cuando existen dos `server` blocks en el mismo puerto sin `server_name`
distintos, Nginx puede resolver al `default.conf` en lugar de al nuestro,
devolviendo 404 porque no tiene documentos estáticos que servir.

**Fix aplicado**

Se añadió una directiva `command` al servicio `nginx` en
[`docker-compose.yml`](docker-compose.yml) que elimina el `default.conf`
antes de iniciar el proceso nginx:

```yaml
# docker-compose.yml — servicio nginx
command: >
  /bin/sh -c "rm -f /etc/nginx/conf.d/default.conf && nginx -g 'daemon off;'"
```

Esto garantiza que el único server block activo sea el de `api.conf`,
independientemente de la versión de la imagen base utilizada.

**Verificación**

```bash
# Confirmar que default.conf fue eliminado del contenedor en ejecución
docker exec logistics_nginx ls /etc/nginx/conf.d/
# Salida esperada: api.conf

# Confirmar que el proxy responde correctamente
curl http://localhost/health
# Salida esperada: {"status":"ok","version":"1.0.0"}
```

## 9. Entorno de Ejecución

El entorno utilizado para el desarrollo y validación de esta API es el siguiente:

### System Details Report
---

#### Report details
- **Date generated:**                              2026-05-27 17:12:38

#### Hardware Information:
- **Hardware Model:**                              Lenovo IdeaPad 3 15ADA05
- **Memory:**                                      8.0 GiB
- **Processor:**                                   AMD Ryzen™ 5 3500U with Radeon™ Vega Mobile Gfx × 8
- **Graphics:**                                    AMD Radeon™ Vega 8 Graphics
- **Disk Capacity:**                               256.1 GB

#### Software Information:
- **Firmware Version:**                            E8CN34WW
- **OS Name:**                                     Ubuntu 26.04 LTS
- **OS Build:**                                    (null)
- **OS Type:**                                     64-bit
- **GNOME Version:**                               50
- **Windowing System:**                            Wayland
- **Kernel Version:**                              Linux 7.0.0-15-generic

## 10. Desarrollo Local y Formateo

Para mantener la calidad y el estilo del código, nuestro pipeline de CI/CD (GitHub Actions) utiliza reglas estrictas de formateo a través de [Ruff](https://docs.astral.sh/ruff/). Si el código enviado en un PR no cumple con estas reglas, el paso `lint-and-test` fallará.

Para evitar fallos en el pipeline y asegurar un formato consistente sin lidiar con los problemas de instalación global de pip en entornos Linux modernos (PEP 668: `externally-managed-environment`), recomendamos ejecutar Ruff a través de un contenedor Docker efímero localmente antes de hacer commit.

### Comando de Formateo Recomendado

Ejecuta el siguiente comando en la raíz del proyecto para aplicar automáticamente las correcciones de formato:

```bash
docker run --rm -v $(pwd):/app -w /app ghcr.io/astral-sh/ruff:latest format .
```

**Explicación del comando (DevSecOps Best Practices):**
- `docker run --rm`: Ejecuta un contenedor efímero que se destruye automáticamente al terminar. No deja basura (dangling containers) en el host.
- `-v $(pwd):/app`: Monta el directorio de trabajo actual en `/app` dentro del contenedor. Los cambios realizados por Ruff se reflejarán directamente en tus archivos locales.
- `-w /app`: Establece `/app` como el directorio de trabajo dentro del contenedor, asegurando que Ruff apunte al lugar correcto.
- `ghcr.io/astral-sh/ruff:latest format .`: Utiliza la imagen oficial de Ruff mantenida por Astral para formatear todo el código en el directorio actual.

**¿Por qué usar este enfoque?**
1. **Consistencia de CI/CD:** Asegura que utilices las mismas reglas de formateo que aplicará el pipeline.
2. **Aislamiento del Entorno:** Evita ensuciar el entorno local de Python y evita conflictos de versiones de dependencias (PEP 668).
3. **Fricción Cero:** Permite formatear el código sin necesidad de configurar y gestionar entornos virtuales (`venv`) solo para el linter.

---

*Logistics Validation API · DevSecOps Technical Challenge*
