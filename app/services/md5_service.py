"""
app/services/md5_service.py
────────────────────────────
Core business logic: deterministic MD5 computation and validation.

═══════════════════════════════════════════════════════════════════
WHY CANONICAL JSON?
═══════════════════════════════════════════════════════════════════
JSON (RFC 8259) does not mandate key ordering in objects.  Two
semantically identical payloads — {"a":1,"b":2} vs {"b":2,"a":1}
— are DIFFERENT byte sequences and therefore produce DIFFERENT hashes.

To make hashing reproducible across any client language or library,
we define one canonical form for a JSON object:

  1. sort_keys=True       → Keys are sorted lexicographically (A-Z).
  2. separators=(',',':') → No whitespace between tokens. Eliminates
                            the ambiguity of compact vs pretty-printed
                            representations (' : ' vs ':').
  3. ensure_ascii=True    → Non-ASCII characters are escaped as \\uXXXX.
                            Prevents encoding divergence across systems
                            that may default to different locale codecs.
  4. .encode('utf-8')     → Produces a byte sequence with a single,
                            unambiguous encoding before hashing.

This approach mirrors the behaviour of JCS (JSON Canonicalization
Scheme, RFC 8785) for the common case of string/number/bool payloads,
without introducing an external dependency.

═══════════════════════════════════════════════════════════════════
WHAT IS HASHED?
═══════════════════════════════════════════════════════════════════
Only the `payload` dictionary is hashed — the `md5_hash` field that
the caller supplies is intentionally excluded.  Including the hash
inside the string being hashed would make the problem circular.

Example round-trip
──────────────────
  payload   = {"status": "shipped", "order_id": 42}
  canonical = '{"order_id":42,"status":"shipped"}'   ← keys sorted
  md5       = hashlib.md5(canonical.encode()).hexdigest()
"""

import hashlib
import json
from typing import Any


def canonicalize(payload: dict[str, Any]) -> str:
    """
    Return the canonical JSON string of *payload*.

    Parameters
    ----------
    payload:
        Any JSON-serialisable dictionary (numbers, strings, booleans,
        nested dicts/lists are all supported).

    Returns
    -------
    str
        A compact, key-sorted, ASCII-safe JSON string.
    """
    return json.dumps(
        payload,
        sort_keys=True,  # Deterministic key ordering
        separators=(",", ":"),  # No whitespace — compact form
        ensure_ascii=True,  # ASCII-safe: non-ASCII → \\uXXXX escapes
    )


def compute_md5(payload: dict[str, Any]) -> tuple[str, str]:
    """
    Compute the MD5 digest of the canonical JSON form of *payload*.

    Parameters
    ----------
    payload:
        The JSON object to hash.

    Returns
    -------
    tuple[str, str]
        A 2-tuple of (hex_digest, canonical_json_string).
        Returning the canonical string alongside the digest enables
        callers to include it in responses for full auditability.
    """
    canonical = canonicalize(payload)

    # MD5 is used here purely as an integrity / fingerprint mechanism
    # as specified by the challenge — NOT for cryptographic security.
    # For security-sensitive use cases, prefer SHA-256 or BLAKE2.
    digest = hashlib.md5(canonical.encode("utf-8")).hexdigest()  # noqa: S324

    return digest, canonical


def validate_md5(payload: dict[str, Any], expected_hash: str) -> tuple[bool, str, str]:
    """
    Validate that *expected_hash* matches the MD5 of *payload*.

    Parameters
    ----------
    payload:
        The JSON object whose integrity is being verified.
    expected_hash:
        The MD5 hex digest provided by the caller.

    Returns
    -------
    tuple[bool, str, str]
        (is_valid, computed_digest, canonical_json_string)

    Notes
    -----
    The comparison uses ``==`` directly on two Python strings of
    identical length (32 hex chars). This is safe against timing-
    attack exploitation because MD5 is not used as an authentication
    secret here.  If this were an HMAC comparison, we would use
    ``hmac.compare_digest`` instead.
    """
    computed, canonical = compute_md5(payload)
    is_valid = computed == expected_hash.lower()
    return is_valid, computed, canonical
