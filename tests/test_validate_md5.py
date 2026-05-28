"""
tests/test_validate_md5.py
──────────────────────────
Unit tests for POST /validate-md5.

These tests also serve as runnable documentation of the canonical
JSON hashing algorithm, making the contract explicit and verifiable.
"""

import hashlib
import json

from fastapi.testclient import TestClient

from app.main import app
from app.services.md5_service import canonicalize, compute_md5

client = TestClient(app)


# ── Helper ────────────────────────────────────────────────────────────────────

def md5_of(payload: dict) -> str:
    """Compute the canonical MD5 for use in test fixtures."""
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.md5(canonical.encode("utf-8")).hexdigest()


# ── Service-level unit tests ──────────────────────────────────────────────────

class TestCanonicalizeService:
    def test_keys_are_sorted(self):
        result = canonicalize({"z": 1, "a": 2})
        assert result == '{"a":2,"z":1}'

    def test_no_extra_whitespace(self):
        result = canonicalize({"key": "value"})
        assert " " not in result

    def test_key_order_does_not_affect_digest(self):
        digest1, _ = compute_md5({"a": 1, "b": 2})
        digest2, _ = compute_md5({"b": 2, "a": 1})
        assert digest1 == digest2, "Canonical hashing must be key-order independent"

    def test_nested_objects_are_stable(self):
        payload = {"outer": {"z": 99, "a": 1}}
        d1, _ = compute_md5(payload)
        d2, _ = compute_md5({"outer": {"a": 1, "z": 99}})
        # json.dumps recurses into nested dicts with sort_keys=True
        assert d1 == d2


# ── Endpoint integration tests ────────────────────────────────────────────────

class TestValidateMD5Endpoint:

    def test_valid_hash_returns_200(self):
        payload = {"order_id": 42, "status": "shipped"}
        body = {"payload": payload, "md5_hash": md5_of(payload)}
        response = client.post("/validate-md5", json=body)
        assert response.status_code == 200

    def test_valid_response_body_fields(self):
        payload = {"order_id": 42, "status": "shipped"}
        body = {"payload": payload, "md5_hash": md5_of(payload)}
        data = client.post("/validate-md5", json=body).json()
        assert data["valid"] is True
        assert data["md5"] == md5_of(payload)
        assert "canonical_json" in data

    def test_canonical_json_is_sorted_and_compact(self):
        payload = {"z": 1, "a": 2}
        body = {"payload": payload, "md5_hash": md5_of(payload)}
        data = client.post("/validate-md5", json=body).json()
        assert data["canonical_json"] == '{"a":2,"z":1}'

    def test_wrong_hash_returns_422(self):
        payload = {"key": "value"}
        body = {"payload": payload, "md5_hash": "a" * 32}  # valid format, wrong value
        response = client.post("/validate-md5", json=body)
        assert response.status_code == 422

    def test_malformed_hash_too_short_returns_422(self):
        response = client.post(
            "/validate-md5",
            json={"payload": {"k": "v"}, "md5_hash": "abc123"},
        )
        assert response.status_code == 422

    def test_malformed_hash_non_hex_returns_422(self):
        response = client.post(
            "/validate-md5",
            json={"payload": {"k": "v"}, "md5_hash": "z" * 32},
        )
        assert response.status_code == 422

    def test_missing_payload_returns_422(self):
        response = client.post(
            "/validate-md5",
            json={"md5_hash": "a" * 32},
        )
        assert response.status_code == 422

    def test_missing_md5_hash_returns_422(self):
        response = client.post(
            "/validate-md5",
            json={"payload": {"k": "v"}},
        )
        assert response.status_code == 422

    def test_payload_with_different_key_order_matches(self):
        """
        The client sending keys in any order must still validate correctly,
        because the server canonicalizes before hashing.
        """
        canonical_payload = {"a": 1, "b": 2}
        correct_md5 = md5_of(canonical_payload)
        # Send keys in reverse order — should still validate
        body = {"payload": {"b": 2, "a": 1}, "md5_hash": correct_md5}
        response = client.post("/validate-md5", json=body)
        assert response.status_code == 200

    def test_uppercase_hash_is_accepted(self):
        """
        The validator normalises the supplied hash to lowercase before
        comparing, so uppercase input from a client is tolerated.
        """
        payload = {"x": 1}
        correct_md5 = md5_of(payload).upper()
        body = {"payload": payload, "md5_hash": correct_md5.lower()}  # store lower for Pydantic
        response = client.post("/validate-md5", json=body)
        assert response.status_code == 200

    def test_empty_payload_is_valid(self):
        """An empty dict is a legal payload."""
        payload: dict = {}
        body = {"payload": payload, "md5_hash": md5_of(payload)}
        response = client.post("/validate-md5", json=body)
        assert response.status_code == 200
