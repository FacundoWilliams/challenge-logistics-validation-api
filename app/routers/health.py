"""
app/routers/health.py
──────────────────────
GET /health — liveness probe endpoint.

Returns a minimal JSON body so that monitoring tools, Docker
healthchecks, and load balancers can distinguish a live process
from a dead container (which would return a TCP error rather than HTTP).
"""

from fastapi import APIRouter
from pydantic import BaseModel

router = APIRouter(tags=["Health"])


class HealthResponse(BaseModel):
    status: str
    version: str


@router.get(
    "/health",
    response_model=HealthResponse,
    summary="Liveness probe",
    description=(
        "Returns HTTP 200 when the service is running. "
        "Intended for use by Docker healthchecks, Nginx upstreams, "
        "and external monitoring systems."
    ),
    responses={
        200: {
            "description": "Service is alive.",
            "content": {
                "application/json": {"example": {"status": "ok", "version": "1.0.0"}}
            },
        }
    },
)
async def health_check() -> HealthResponse:
    # Import here to avoid a circular import at module load time.
    from app.core.config import settings

    return HealthResponse(status="ok", version=settings.APP_VERSION)
