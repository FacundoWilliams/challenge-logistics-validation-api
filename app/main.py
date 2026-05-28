"""
app/main.py
───────────
FastAPI application factory and entrypoint.

Responsibilities:
  - Instantiate the FastAPI app with OpenAPI/Swagger metadata.
  - Register all routers under their respective prefixes.
  - Expose a lifespan handler for startup/shutdown logging.
  - Conditionally disable /docs and /redoc in production via settings.
"""

import logging
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.routers import health, validate_md5

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)


# ── Lifespan (replaces deprecated @app.on_event) ─────────────────────────────
@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncGenerator[None, None]:
    logger.info("🚀  %s v%s starting up", settings.APP_NAME, settings.APP_VERSION)
    yield
    logger.info("🛑  %s shutting down", settings.APP_NAME)


# ── Application factory ───────────────────────────────────────────────────────
def create_app() -> FastAPI:
    """
    Build and configure the FastAPI application.

    Separating construction into a factory function makes the app
    easily importable in tests without side-effects.
    """
    app = FastAPI(
        title=settings.APP_NAME,
        version=settings.APP_VERSION,
        description=settings.APP_DESCRIPTION,
        # Swagger UI available at /docs; disable in prod by setting DOCS_ENABLED=false
        docs_url="/docs" if settings.DOCS_ENABLED else None,
        redoc_url="/redoc" if settings.DOCS_ENABLED else None,
        openapi_url="/openapi.json" if settings.DOCS_ENABLED else None,
        lifespan=lifespan,
        # Contact / license metadata displayed in Swagger UI
        contact={"name": "DevSecOps Team", "email": "devsecops@logistics.local"},
        license_info={"name": "Private"},
    )

    # ── CORS ──────────────────────────────────────────────────────────────────
    # Locked down by default. Adjust origins for real deployments.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],  # Tighten to specific domains in production
        allow_methods=["GET", "POST"],
        allow_headers=["Content-Type"],
    )

    # ── Routers ───────────────────────────────────────────────────────────────
    app.include_router(health.router)
    app.include_router(validate_md5.router)

    return app


# Module-level app instance consumed by Uvicorn / Docker CMD.
app = create_app()
