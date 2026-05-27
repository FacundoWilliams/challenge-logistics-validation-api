"""
app/schemas/md5.py
──────────────────
Pydantic models that define the public contract of POST /validate-md5.

Design decisions:
  - The request carries an arbitrary JSON object (the "payload") plus the
    expected MD5 hash in a dedicated field called `md5_hash`.
  - Using `dict[str, Any]` for the payload allows any valid JSON object
    while still being validated by Pydantic (non-objects are rejected).
  - `md5_hash` is validated with a regex to ensure it is a lowercase
    32-character hexadecimal string before any business logic runs.
    This prevents wasted computation on obviously malformed inputs.
"""

import re
from typing import Any

from pydantic import BaseModel, Field, field_validator


# Pre-compiled regex for a valid MD5 hex digest (32 lowercase hex chars).
_MD5_PATTERN = re.compile(r"^[0-9a-f]{32}$")


class MD5ValidateRequest(BaseModel):
    """
    Request body for POST /validate-md5.

    The caller must supply:
      - An arbitrary JSON object as `payload`.
      - The expected MD5 digest of that payload (computed using the
        canonical JSON form defined in md5_service.py) as `md5_hash`.

    Example::

        {
          "payload": {"order_id": 42, "status": "shipped"},
          "md5_hash": "d41d8cd98f00b204e9800998ecf8427e"
        }
    """

    payload: dict[str, Any] = Field(
        ...,
        description=(
            "Arbitrary JSON object whose MD5 integrity will be validated. "
            "Keys are sorted lexicographically before hashing."
        ),
        examples=[{"order_id": 42, "status": "shipped"}],
    )

    md5_hash: str = Field(
        ...,
        description="Expected MD5 hex digest (32 lowercase hexadecimal characters).",
        examples=["d41d8cd98f00b204e9800998ecf8427e"],
    )

    @field_validator("md5_hash")
    @classmethod
    def validate_md5_format(cls, value: str) -> str:
        """Reject hashes that are not 32 lowercase hex characters early."""
        if not _MD5_PATTERN.match(value):
            raise ValueError(
                "md5_hash must be a 32-character lowercase hexadecimal string."
            )
        return value

    model_config = {
        "json_schema_extra": {
            "examples": [
                {
                    "payload": {"order_id": 42, "status": "shipped"},
                    "md5_hash": "6e7c9a1d2b8f3e4a5c0d1f2e3a4b5c6d",
                }
            ]
        }
    }


class MD5ValidateResponse(BaseModel):
    """
    Successful response body for POST /validate-md5.

    Fields:
      - `valid`         : Always True in a 200 response.
      - `md5`           : The computed MD5 digest (matches the supplied hash).
      - `canonical_json`: The exact string that was hashed, for auditability.
    """

    valid: bool = Field(True, description="Always True on a 200 OK response.")
    md5: str = Field(..., description="Computed MD5 hex digest of the canonical JSON.")
    canonical_json: str = Field(
        ...,
        description=(
            "The exact UTF-8 string that was fed to the MD5 function. "
            "Keys are sorted, no extra whitespace, ASCII-safe encoding."
        ),
    )


class ErrorDetail(BaseModel):
    """Standard error response body."""

    detail: str = Field(..., description="Human-readable error description.")
