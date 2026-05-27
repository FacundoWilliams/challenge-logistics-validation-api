"""
app/core/config.py
──────────────────
Centralized application settings loaded from environment variables.
Using pydantic-settings gives us automatic .env file support,
type coercion, and validation for free.
"""

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # ── Application metadata ──────────────────────────────────────────
    APP_NAME: str = "Logistics Validation API"
    APP_VERSION: str = "1.0.0"
    APP_DESCRIPTION: str = (
        "REST API for MD5 payload integrity validation. "
        "Hashes are computed over a canonical JSON representation "
        "(RFC-compliant key sorting, no extra whitespace, UTF-8 encoding)."
    )

    # ── Server ────────────────────────────────────────────────────────
    # These are consumed by the start script / Docker CMD, not by FastAPI
    # directly, but centralizing them avoids magic strings in shell scripts.
    HOST: str = "0.0.0.0"
    PORT: int = 8000

    # ── Behaviour ────────────────────────────────────────────────────
    # Set to False in production to suppress the /docs and /redoc UIs
    # (behind Nginx they should be protected or disabled).
    DOCS_ENABLED: bool = True

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
    )


# Single shared instance — import this everywhere instead of
# instantiating Settings() multiple times.
settings = Settings()
