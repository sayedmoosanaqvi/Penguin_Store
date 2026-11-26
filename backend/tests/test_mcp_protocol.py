"""Comprehensive test suite for Penguin Store MCP 2026-07-28 & 2025-11-25 Server."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

backend_dir = str(Path(__file__).resolve().parents[1])
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.mcp import PROTOCOL_VERSION_2025_11_25, PROTOCOL_VERSION_2026_07_28
from app.mcp.auth import create_key, generate_key, hash_key
from app.mcp.audit import reset_for_tests


@pytest.fixture(autouse=True)
def clean_audit_and_cache():
    reset_for_tests()
    yield


@pytest.fixture
def client():
    return TestClient(app)


def test_mcp_discover_2026_07_28(client: TestClient):
    req = {
        "jsonrpc": "2.0",
        "id": "disc-test-1",
        "method": "server/discover",
    }
    resp = client.post(
        "/mcp",
        json=req,
        headers={"MCP-Protocol-Version": PROTOCOL_VERSION_2026_07_28},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["jsonrpc"] == "2.0"
    assert data["id"] == "disc-test-1"
    res = data["result"]
    assert res["protocolVersion"] == PROTOCOL_VERSION_2026_07_28
    assert "penguin-store" in res["serverInfo"]["name"]
    assert "tools" in res["capabilities"]
    assert "resources" in res["capabilities"]
    assert "prompts" in res["capabilities"]


def test_mcp_initialize_2025_11_25_backward_compat(client: TestClient):
    req = {
        "jsonrpc": "2.0",
        "id": 101,
        "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL_VERSION_2025_11_25,
            "capabilities": {},
            "clientInfo": {"name": "LegacyClient", "version": "1.0"},
        },
    }
    resp = client.post(
        "/mcp",
        json=req,
        headers={"MCP-Protocol-Version": PROTOCOL_VERSION_2025_11_25},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["jsonrpc"] == "2.0"
    assert data["id"] == 101
    assert data["result"]["protocolVersion"] == PROTOCOL_VERSION_2025_11_25


def test_mcp_tools_list(client: TestClient):
    req = {
        "jsonrpc": "2.0",
        "id": "tools-1",
        "method": "tools/list",
    }
    resp = client.post("/mcp", json=req)
    assert resp.status_code == 200
    data = resp.json()
    tools = data["result"]["tools"]
    tool_names = [t["name"] for t in tools]
    assert "search_catalog" in tool_names
    assert "calculate_pricing_and_deals" in tool_names
    assert "audit_product_reviews" in tool_names
    assert "list_3d_showcase_models" in tool_names


def test_mcp_tools_call_pricing(client: TestClient):
    req = {
        "jsonrpc": "2.0",
        "id": "call-price-1",
        "method": "tools/call",
        "params": {
            "name": "calculate_pricing_and_deals",
            "arguments": {
                "product_id": 144,
                "quantity": 10,
                "promo_code": "PENGUIN10",
                "gift_wrap": True,
            },
        },
    }
    resp = client.post("/mcp", json=req)
    assert resp.status_code == 200
    data = resp.json()
    assert "result" in data
    content = data["result"]["content"][0]["text"]
    quote = json.loads(content)
    assert quote["quantity"] == 10
    assert quote["b2b_savings"] > 0  # 10 items qualifies for 12% MOQ
    assert quote["promo_discount"] > 0  # PENGUIN10 gives 10%
    assert quote["add_on_cost"] == 99.9  # gift wrap: 10 items * $9.99


def test_mcp_tools_call_invalid_schema(client: TestClient):
    req = {
        "jsonrpc": "2.0",
        "id": "err-1",
        "method": "tools/call",
        "params": {
            "name": "calculate_pricing_and_deals",
            "arguments": {
                "product_id": "not-an-int"
            },
        },
    }
    resp = client.post("/mcp", json=req)
    assert resp.status_code == 200
    data = resp.json()
    assert "error" in data
    assert data["error"]["code"] == -32602  # Invalid params


def test_mcp_resources_list_and_read(client: TestClient):
    req_list = {
        "jsonrpc": "2.0",
        "id": "res-list-1",
        "method": "resources/list",
    }
    resp = client.post("/mcp", json=req_list)
    assert resp.status_code == 200
    resources = resp.json()["result"]["resources"]
    uris = [r["uri"] for r in resources]
    assert "penguin://store/manifest" in uris

    req_read = {
        "jsonrpc": "2.0",
        "id": "res-read-1",
        "method": "resources/read",
        "params": {"uri": "penguin://store/manifest"},
    }
    resp_read = client.post("/mcp", json=req_read)
    assert resp_read.status_code == 200
    content = resp_read.json()["result"]["contents"][0]["text"]
    assert "Penguin Store" in content


def test_mcp_prompts_list_and_get(client: TestClient):
    req_list = {
        "jsonrpc": "2.0",
        "id": "prompt-list-1",
        "method": "prompts/list",
    }
    resp = client.post("/mcp", json=req_list)
    assert resp.status_code == 200
    prompts = resp.json()["result"]["prompts"]
    names = [p["name"] for p in prompts]
    assert "budget_bundle_architect" in names

    req_get = {
        "jsonrpc": "2.0",
        "id": "prompt-get-1",
        "method": "prompts/get",
        "params": {
            "name": "budget_bundle_architect",
            "arguments": {"occasion": "holiday gift", "max_budget": "250"},
        },
    }
    resp_get = client.post("/mcp", json=req_get)
    assert resp_get.status_code == 200
    messages = resp_get.json()["result"]["messages"]
    assert len(messages) >= 1
    assert "250" in messages[0]["content"]["text"]


def test_mcp_well_known_manifest(client: TestClient):
    resp = client.get("/.well-known/mcp.json")
    assert resp.status_code == 200
    data = resp.json()
    assert "penguin-store" in data["name"]
    assert data["protocolVersion"] == PROTOCOL_VERSION_2026_07_28


def test_mcp_telemetry_endpoint(client: TestClient):
    resp = client.get("/api/v1/mcp/telemetry")
    assert resp.status_code == 200
    data = resp.json()
    assert "metrics" in data
    assert "recent_invocations" in data
