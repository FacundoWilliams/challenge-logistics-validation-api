"""
app/routers/validate_md5.py
────────────────────────────
POST /validate-md5 — payload integrity validation endpoint.

Flow
────
  1. FastAPI + Pydantic parse and validate the request body.
     A malformed md5_hash (wrong length, non-hex chars) is rejected
     here with 422 before any business logic executes.

  2. The router delegates to md5_service.validate_md5(), which:
       a. Builds the canonical JSON string (sorted keys, no spaces).
       b. Computes the MD5 over its UTF-8 byte encoding.
       c. Compares the result with the caller-supplied hash.

  3. On mismatch → 422 Unprocessable Entity with a descriptive body.
     On match    → 200 OK with the verified digest + canonical string.

HTTP status rationale
─────────────────────
  422 Unprocessable Entity is semantically correct for a hash mismatch:
  the request is well-formed JSON (not a 400 Bad Request) but the
  *semantic* integrity check failed (the payload does not match the
  claimed hash). This mirrors how FastAPI itself signals validation
  failures and is consistent with RFC 9110 §15.5.21.
"""

from fastapi import APIRouter, HTTPException, status

from app.schemas.md5 import MD5ValidateRequest, MD5ValidateResponse
from app.services.md5_service import validate_md5

router = APIRouter(tags=["Validation"])


@router.post(
    "/validate-md5",
    response_model=MD5ValidateResponse,
    status_code=status.HTTP_200_OK,
    summary="Validate MD5 hash of a JSON payload",
    description="""
Receives a JSON object (`payload`) and an expected MD5 hex digest (`md5_hash`).

**Canonical JSON rules applied before hashing:**

| Rule | Value | Reason |
|---|---|---|
| Key ordering | Lexicographic (`sort_keys=True`) | Deterministic regardless of client key insertion order |
| Separators | `(',', ':')` — no spaces | Eliminates whitespace ambiguity |
| Encoding | ASCII-safe (`ensure_ascii=True`) | Prevents Unicode codec divergence |
| Byte encoding | UTF-8 | Internet standard for text exchange |
| Excluded field | `md5_hash` itself | Hashing the hash would be circular |

Returns **200 OK** with the computed digest and the exact string that was hashed.  
Returns **422 Unprocessable Entity** if the hash does not match or is malformed.
""",
    responses={
        200: {
            "description": "Hash is valid — payload integrity confirmed.",
            "content": {
                "application/json": {
                    "example": {
                        "valid": True,
                        "md5": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4",
                        "canonical_json": '{"order_id":42,"status":"shipped"}',
                    }
                }
            },
        },
        422: {
            "description": "Hash mismatch or malformed md5_hash field.",
            "content": {
                "application/json": {
                    "example": {
                        "detail": (
                            "MD5 mismatch. "
                            "Expected: 'deadbeef...', "
                            "Computed: 'a1b2c3d4...' "
                            "over canonical JSON: "
                            "'{\"order_id\":42,\"status\":\"shipped\"}'"
                        )
                    }
                }
            },
        },
    },
)
async def validate_md5_endpoint(body: MD5ValidateRequest) -> MD5ValidateResponse:
    """
    Validate that `body.md5_hash` matches the MD5 of `body.payload`.
    """
    is_valid, computed, canonical = validate_md5(body.payload, body.md5_hash)

    if not is_valid:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"MD5 mismatch. "
                f"Expected: '{body.md5_hash}', "
                f"Computed: '{computed}' "
                f"over canonical JSON: '{canonical}'"
            ),
        )

    return MD5ValidateResponse(
        valid=True,
        md5=computed,
        canonical_json=canonical,
    )
