"""Autonomous External Buyer Agent: a Groq-driven MCP *client* that talks to Penguin Store's
own `/mcp` endpoint over real JSON-RPC 2.0 (through the ASGI stack, middleware included).

The simulator is deliberately anonymous/read-only so it can run safely against the live store.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from typing import Any, Optional

import httpx
from starlette.concurrency import run_in_threadpool

from app.mcp import registry
from app.mcp.protocol import (
    LATEST_VERSION,
    META_CLIENT_INFO,
    META_PROTOCOL_VERSION,
)

logger = logging.getLogger(__name__)

PRIMARY_MODEL = os.getenv("MCP_AGENT_MODEL", "openai/gpt-oss-20b")
FALLBACK_MODEL = "llama-3.3-70b-versatile"
MAX_RESULT_CHARS_FOR_LLM = 2400

SYSTEM_PROMPT = (
    "You are an autonomous external buyer agent connected to the Penguin Store MCP server. "
    "You can only use the read-only tools provided. Plan step by step, call at most one tool per turn, "
    "and ground every claim in tool results. Respond with ONLY one JSON object:\n"
    '{"thought": "<short reasoning>", "action": "call_tool" | "read_resource" | "final", '
    '"name": "<tool name>", "arguments": {...}, "uri": "<resource uri>", '
    '"answer": "<final buyer-facing answer, only when action is final>"}\n'
    "Finish with action=final once you can recommend concrete products with prices."
)


def _tools_brief() -> str:
    lines = []
    for tool in registry.TOOLS.values():
        if tool.scope != "catalog:read":
            continue
        props = ", ".join(
            f"{k}:{v.get('type', 'any')}" for k, v in tool.properties.items()
        )
        req = ",".join(tool.required) or "none"
        lines.append(f"- {tool.name}({props}) required=[{req}] — {tool.description[:140]}")
    return "\n".join(lines)


def _compact(structured: Any) -> str:
    try:
        if isinstance(structured, dict) and isinstance(structured.get("products"), list):
            slim = {
                **{k: v for k, v in structured.items() if k not in ("products", "filters")},
                "products": [
                    {
                        k: p.get(k)
                        for k in ("id", "name", "price", "category", "stock", "has_3d_model", "rating")
                    }
                    for p in structured["products"][:8]
                ],
            }
            text = json.dumps(slim, ensure_ascii=False)
        else:
            text = json.dumps(structured, ensure_ascii=False, default=str)
    except Exception:
        text = str(structured)
    return text[:MAX_RESULT_CHARS_FOR_LLM]


def _collect_products(structured: Any, bucket: dict[int, dict[str, Any]]) -> None:
    if not isinstance(structured, dict):
        return
    candidates: list[Any] = []
    for key in ("products", "items"):
        if isinstance(structured.get(key), list):
            candidates.extend(structured[key])
    if isinstance(structured.get("winner"), dict):
        candidates.append(structured["winner"])
    for p in structured.get("products", []) if key == "products" else []:
        pass
    if isinstance(structured.get("product"), dict):
        candidates.append(structured["product"])
    for p in candidates:
        if not isinstance(p, dict):
            continue
        pid = p.get("id") or p.get("product_id") or p.get("winner_product_id")
        try:
            pid = int(pid)
        except (TypeError, ValueError):
            continue
        if pid in bucket:
            continue
        bucket[pid] = {
            "id": pid,
            "name": p.get("name") or p.get("winner_name"),
            "price": p.get("price") or p.get("winner_price"),
            "category": p.get("category"),
            "image_url": p.get("image_url") or p.get("winner_image_url") or "",
            "rating": p.get("rating"),
            "stock": p.get("stock"),
            "has_3d_model": bool(p.get("has_3d_model") or p.get("has_3d")),
        }


def _extract_json(text: str) -> Optional[dict[str, Any]]:
    if not text:
        return None
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else None
    except ValueError:
        pass
    match = re.search(r"\{.*\}", text, flags=re.DOTALL)
    if match:
        try:
            parsed = json.loads(match.group(0))
            return parsed if isinstance(parsed, dict) else None
        except ValueError:
            return None
    return None


def _ask_llm(messages: list[dict[str, str]]) -> tuple[Optional[dict[str, Any]], str]:
    api_key = (os.getenv("GROQ_API_KEY") or "").strip()
    if not api_key:
        return None, ""
    import groq

    client = groq.Groq(api_key=api_key, timeout=18.0)
    for model in (PRIMARY_MODEL, FALLBACK_MODEL):
        for use_json_mode in (True, False):
            try:
                kwargs: dict[str, Any] = {
                    "model": model,
                    "messages": messages,
                    "temperature": 0.2,
                    "max_tokens": 700,
                }
                if use_json_mode:
                    kwargs["response_format"] = {"type": "json_object"}
                resp = client.chat.completions.create(**kwargs)
                decision = _extract_json(resp.choices[0].message.content or "")
                if decision:
                    return decision, model
            except Exception as exc:
                logger.info("MCP agent LLM %s (json=%s) failed: %s", model, use_json_mode, exc)
    return None, ""


# ---------------------------------------------------------------------------
# Deterministic planner (used when Groq is rate-limited / unavailable)
# ---------------------------------------------------------------------------

_FILLER = re.compile(
    r"\b(find|show|get|build|make|compare|calculate|via|using|mcp|top|best|me|a|an|the|and|with|view|"
    r"trustworthy|trusted|under|below|for|units?|bulk|b2b|price|prices|pricing|bundle|party|please|"
    r"products?|over|within|budget|of|to|2|two|3d)\b|\$\s*\d+|\d+",
    flags=re.IGNORECASE,
)


def _parse_goal(goal: str) -> dict[str, Any]:
    g = goal.lower()
    budget = None
    for pat in (r"(?:under|below|less than|max|within|budget(?: of)?)\s*\$?\s*(\d+(?:\.\d+)?)", r"\$\s*(\d+(?:\.\d+)?)"):
        m = re.search(pat, g)
        if m:
            budget = float(m.group(1))
            break
    qty_m = re.search(r"(\d+)\s*(?:units?|pcs|pieces)", g)
    query = " ".join(_FILLER.sub(" ", goal).split()).strip()
    return {
        "budget": budget,
        "qty": int(qty_m.group(1)) if qty_m else None,
        "only_3d": "3d" in g,
        "compare": "compare" in g,
        "bulk": bool(qty_m) or any(w in g for w in ("b2b", "bulk", "wholesale")),
        "bundle": "bundle" in g or "party" in g,
        "query": query,
    }


async def run_agent(app: Any, goal: str, max_steps: int = 4) -> dict[str, Any]:
    started = time.perf_counter()
    hops: list[dict[str, Any]] = []
    matched: dict[int, dict[str, Any]] = {}
    transport = httpx.ASGITransport(app=app, client=("127.0.0.1", 0))

    async with httpx.AsyncClient(
        transport=transport, base_url="http://penguin.mcp.local", timeout=40.0
    ) as http:

        async def rpc(
            method: str,
            params: Optional[dict[str, Any]] = None,
            label: str = "",
            kind: str = "rpc",
        ) -> dict[str, Any]:
            hop_id = len(hops) + 1
            body_params = dict(params or {})
            body_params["_meta"] = {
                META_PROTOCOL_VERSION: LATEST_VERSION,
                META_CLIENT_INFO: {"name": "penguin-buyer-agent", "version": "1.0.0"},
            }
            body = {"jsonrpc": "2.0", "id": hop_id, "method": method, "params": body_params}
            headers = {
                "Content-Type": "application/json",
                "Accept": "application/json",
                "MCP-Protocol-Version": LATEST_VERSION,
                "Mcp-Method": method,
                "X-MCP-Source": "simulator",
            }
            ident = body_params.get("name") or body_params.get("uri")
            if ident:
                headers["Mcp-Name"] = str(ident)

            t0 = time.perf_counter()
            resp = await http.post("/mcp", json=body, headers=headers)
            latency = round((time.perf_counter() - t0) * 1000.0, 2)
            try:
                data = resp.json()
            except ValueError:
                data = {"error": {"code": -32603, "message": f"HTTP {resp.status_code}"}}
            hops.append(
                {
                    "step": hop_id,
                    "kind": kind,
                    "label": label or method,
                    "method": method,
                    "name": ident,
                    "http_status": resp.status_code,
                    "latency_ms": latency,
                    "request": {"headers": headers, "body": body},
                    "response": data,
                }
            )
            return data

        async def call_tool(name: str, args: dict[str, Any], label: str) -> dict[str, Any]:
            data = await rpc("tools/call", {"name": name, "arguments": args}, label, "tool_call")
            result = data.get("result") or {}
            structured = result.get("structuredContent")
            if structured is None:
                err = data.get("error") or {}
                structured = {"error": err.get("message", "Tool call failed.")}
            _collect_products(structured, matched)
            return structured

        # Hop 1-2: mandatory discovery, then enumerate capabilities.
        await rpc("server/discover", {}, "Discover server capabilities", "discover")
        await rpc("tools/list", {}, "List available tools", "tools_list")

        mode = "heuristic"
        model_used = ""
        answer = ""

        messages: list[dict[str, str]] = [
            {"role": "system", "content": SYSTEM_PROMPT + "\n\nTOOLS:\n" + _tools_brief()},
            {"role": "user", "content": f"Buyer goal: {goal}"},
        ]
        llm_failed = False
        for _ in range(max_steps):
            decision, model = await run_in_threadpool(_ask_llm, messages)
            if decision is None:
                llm_failed = True
                break
            mode, model_used = "groq-llm", model
            action = str(decision.get("action") or "").lower()
            messages.append({"role": "assistant", "content": json.dumps(decision)[:1500]})

            if action == "call_tool" and decision.get("name") in registry.TOOLS:
                name = str(decision["name"])
                tool = registry.TOOLS[name]
                if tool.scope != "catalog:read":
                    messages.append({"role": "user", "content": f"Tool {name} is not permitted for this agent."})
                    continue
                args = decision.get("arguments") if isinstance(decision.get("arguments"), dict) else {}
                structured = await call_tool(name, args, f"Call {name}")
                messages.append({"role": "user", "content": f"RESULT of {name}: {_compact(structured)}"})
            elif action == "read_resource" and str(decision.get("uri") or "").startswith("penguin://"):
                data = await rpc(
                    "resources/read",
                    {"uri": decision["uri"]},
                    f"Read {decision['uri']}",
                    "resource",
                )
                text = json.dumps(data.get("result") or data.get("error") or {})[:MAX_RESULT_CHARS_FOR_LLM]
                messages.append({"role": "user", "content": f"RESULT of resource: {text}"})
            else:
                answer = str(decision.get("answer") or "").strip()
                break

        if llm_failed and not any(h["kind"] == "tool_call" for h in hops):
            mode = "heuristic"
            answer = await _run_heuristic(goal, call_tool, rpc)
        elif not answer:
            mode = mode if mode == "groq-llm" else "heuristic"
            answer = _compose_answer(goal, matched)

    products = list(matched.values())[:8]
    return {
        "goal": goal,
        "mode": mode,
        "model": model_used or None,
        "protocol_version": LATEST_VERSION,
        "answer": answer,
        "hops": hops,
        "hop_count": len(hops),
        "matched_products": products,
        "total_latency_ms": round((time.perf_counter() - started) * 1000.0, 2),
    }


def _compose_answer(goal: str, matched: dict[int, dict[str, Any]]) -> str:
    items = list(matched.values())[:3]
    if not items:
        return "I explored the Penguin Store MCP server but found no in-stock products matching that goal."
    lines = [
        f"{p['name']} at ${float(p['price'] or 0):.2f}" + (" (3D view available)" if p.get("has_3d_model") else "")
        for p in items
    ]
    return "Based on live Penguin Store data over MCP, I recommend: " + "; ".join(lines) + "."


async def _run_heuristic(goal: str, call_tool: Any, rpc: Any) -> str:
    plan = _parse_goal(goal)
    facts: list[str] = []

    if plan["bundle"]:
        await rpc(
            "prompts/get",
            {"name": "budget_bundle_architect", "arguments": {"occasion": "party", "max_budget": str(plan["budget"] or 250)}},
            "Load bundle prompt",
            "prompt",
        )

    args: dict[str, Any] = {"query": plan["query"], "limit": 6, "in_stock_only": True}
    if plan["budget"] and not plan["bundle"]:
        args["max_price"] = plan["budget"]
    if plan["only_3d"]:
        args["only_3d"] = True
    found = await call_tool("search_catalog", args, "Search the live catalog")
    products = [p for p in (found.get("products") or []) if isinstance(p, dict)]

    if plan["bundle"]:
        budget = plan["budget"] or 250.0
        extra = await call_tool(
            "search_catalog",
            {"occasion": "party", "max_price": round(budget / 2, 2), "limit": 8},
            "Search party-ready items",
        )
        pool = {p["id"]: p for p in products + [x for x in extra.get("products", []) if isinstance(x, dict)]}
        chosen: list[dict[str, Any]] = []
        total = 0.0
        for p in sorted(pool.values(), key=lambda x: (-(x.get("rating") or 0), x.get("price") or 0)):
            if total + float(p.get("price") or 0) <= budget and len(chosen) < 3:
                chosen.append(p)
                total += float(p.get("price") or 0)
        if chosen:
            facts.append(
                "Bundle under budget: "
                + ", ".join(f"{p['name']} (${p['price']:.2f})" for p in chosen)
                + f" for ${total:.2f} (budget ${budget:.0f})."
            )
        return " ".join(facts) or _compose_answer(goal, {})

    if plan["compare"] and len(products) >= 2:
        cmp_res = await call_tool(
            "compare_and_score_products",
            {"product_ids": [products[0]["id"], products[1]["id"]], "priority": "best_value"},
            "Compare and score top two",
        )
        winner = cmp_res.get("winner") or {}
        if winner.get("name"):
            facts.append(f"Verified winner: {winner['name']}.")

    if products and (plan["bulk"] or plan["qty"]):
        qty = plan["qty"] or 25
        deal = await call_tool(
            "calculate_pricing_and_deals",
            {"product_id": products[0]["id"], "quantity": qty},
            f"Price {qty} units (B2B MOQ)",
        )
        if deal.get("b2b_unit_price") is not None:
            facts.append(
                f"{qty} units of {deal['product_name']}: {deal['b2b_tier_label']} at "
                f"${deal['b2b_unit_price']:.2f}/unit, final total ${deal['final_total']:.2f}."
            )

    if products and not facts:
        audit_res = await call_tool(
            "audit_product_reviews", {"product_id": products[0]["id"]}, "Audit review trust"
        )
        if audit_res.get("trust_score") is not None:
            facts.append(
                f"Top match {products[0]['name']} (${products[0]['price']:.2f}) has trust score "
                f"{audit_res['trust_score']}."
            )

    return " ".join(facts) or "No in-stock products matched that goal."
