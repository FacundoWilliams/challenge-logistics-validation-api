"""tests/test_health.py — Unit tests for GET /health."""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_health_returns_200():
    response = client.get("/health")
    assert response.status_code == 200


def test_health_body_structure():
    response = client.get("/health")
    body = response.json()
    assert body["status"] == "ok"
    assert "version" in body
