#!/usr/bin/env python3
"""Verification client script for Penguin Store MCP 2026-07-28 / 2025-11-25 server."""

import json
import urllib.request
import sys

BASE_URL = "http://127.0.0.1:8000"
MCP_ENDPOINT = f"{BASE_URL}/mcp"


def call_mcp(method: str, params: dict | None = None, req_id: int | str = 1, version: str = "2026-07-28", token: str | None = None) -> dict:
    body = {
        "jsonrpc": "2.0",
        "id": req_id,
        "method": method,
    }
    if params is not None:
        body["params"] = params

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "MCP-Protocol-Version": version,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(
        MCP_ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        return json.loads(err.read().decode("utf-8"))
    except Exception as exc:
        return {"error": str(exc)}


def main() -> None:
    print("=== Testing Penguin Store MCP Server ===")
    
    # 1. 2026-07-28 server/discover
    print("\n1. Testing server/discover (2026-07-28)...")
    res = call_mcp("server/discover", req_id="disc-1", version="2026-07-28")
    print(f"Result: {json.dumps(res, indent=2)[:400]}...")

    # 2. 2025-11-25 initialize
    print("\n2. Testing initialize (2025-11-25 backward-compatibility)...")
    res = call_mcp("initialize", {"protocolVersion": "2025-11-25", "clientInfo": {"name": "TestClient", "version": "1.0"}}, req_id="init-1", version="2025-11-25")
    print(f"Result: {json.dumps(res, indent=2)[:400]}...")

    # 3. tools/list
    print("\n3. Testing tools/list...")
    res = call_mcp("tools/list", req_id="tools-1")
    tools = res.get("result", {}).get("tools", [])
    print(f"Found {len(tools)} tools: {[t['name'] for t in tools]}")

    # 4. tools/call search_catalog
    print("\n4. Testing tools/call 'search_catalog'...")
    res = call_mcp("tools/call", {"name": "search_catalog", "arguments": {"query": "penguin", "limit": 3}}, req_id="call-1")
    print(f"Result: {json.dumps(res, indent=2)[:400]}...")

    # 5. tools/call calculate_pricing_and_deals
    print("\n5. Testing tools/call 'calculate_pricing_and_deals'...")
    res = call_mcp("tools/call", {
        "name": "calculate_pricing_and_deals",
        "arguments": {
            "items": [{"product_id": 144, "quantity": 10, "unit_price": 50.0}],
            "promo_code": "PENGUIN10",
        }
    }, req_id="call-2")
    print(f"Result: {json.dumps(res, indent=2)[:500]}...")

    # 6. resources/list
    print("\n6. Testing resources/list...")
    res = call_mcp("resources/list", req_id="res-1")
    print(f"Result: {json.dumps(res, indent=2)[:400]}...")

    # 7. prompts/list
    print("\n7. Testing prompts/list...")
    res = call_mcp("prompts/list", req_id="prompts-1")
    print(f"Result: {json.dumps(res, indent=2)[:400]}...")

    print("\n=== MCP Verification Complete ===")


if __name__ == "__main__":
    main()
