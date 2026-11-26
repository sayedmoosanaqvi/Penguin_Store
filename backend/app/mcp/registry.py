"""Unified real-database MCP registry (tools, resources, templates, prompts).

Single source of truth shared by:
  * external MCP hosts (Claude Desktop, VS Code, Cursor, MCP Inspector) via `POST /mcp`
  * CTRL-X and the Penguin Voice Concierge (via `invoke_internal`)
  * the Autonomous External Buyer Agent simulator

Every read enforces `is_active = true`; there is zero mock data.
"""

from __future__ import annotations

import json
import logging
import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Optional

from app.core.supabase_rest import (
    fetch_3d_catalog_ids_https,
    fetch_3d_showcase_https,
    fetch_product_3d_assets_https,
    fetch_product_by_id_https,
    fetch_products_https,
    get_supabase_client,
    is_product_active_row,
)
from app.mcp.auth import (
    SCOPE_ADMIN_READ,
    SCOPE_B2B_WRITE,
    SCOPE_CATALOG_READ,
    SCOPE_COMMERCE_WRITE,
    Principal,
    enforce_scope,
)
from app.mcp.pricing import (
    ADDON_CATALOG,
    MOQ_TIERS,
    PROMO_CODES,
    authoritative_deal_quote,
    moq_tiers_for,
    variant_options,
)
from app.mcp.protocol import (
    INVALID_PARAMS,
    JSON_SCHEMA_DIALECT,
    LATEST_VERSION,
    LEGACY_VERSION,
    RESOURCE_NOT_FOUND_LEGACY,
    MCPError,
    ToolExecutionError,
    validate_arguments,
)

logger = logging.getLogger(__name__)

SERVER_NAME = "penguin-store-mcp"
SERVER_TITLE = "Penguin Store Commerce MCP"
SERVER_VERSION = "1.0.0"
PUBLIC_API_BASE = os.getenv(
    "PUBLIC_API_BASE_URL", "https://penguin-store-backend.onrender.com"
).rstrip("/")

Handler = Callable[[Optional[Principal], dict[str, Any]], dict[str, Any]]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _jsonable(obj: Any) -> Any:
    return json.loads(json.dumps(obj, default=str))


def _abs_image(url: Any) -> str:
    raw = str(url or "").strip()
    if raw.startswith("/"):
        return f"{PUBLIC_API_BASE}{raw}"
    return raw


def _active(product_id: int) -> dict[str, Any]:
    row = fetch_product_by_id_https(int(product_id))
    if row is None or not is_product_active_row(row):
        raise ToolExecutionError(f"Product #{product_id} was not found or is no longer active.")
    return row


def _pub(p: dict[str, Any], three_d_ids: Optional[set[int]] = None) -> dict[str, Any]:
    pid = int(p.get("id") or 0)
    stock = int(p.get("stock") if p.get("stock") is not None else 50)
    has_3d = bool(
        p.get("has_3d_model")
        or p.get("has_3d")
        or (three_d_ids is not None and pid in three_d_ids)
    )
    out = {
        "id": pid,
        "name": str(p.get("name") or ""),
        "price": round(float(p.get("price") or 0.0), 2),
        "original_price": p.get("original_price"),
        "category": str(p.get("category") or ""),
        "image_url": _abs_image(p.get("image_url")),
        "rating": p.get("rating"),
        "reviews": p.get("reviews"),
        "stock": stock,
        "in_stock": stock > 0,
        "is_featured": bool(p.get("is_featured", False)),
        "has_3d_model": has_3d,
        "description": str(p.get("description") or "")[:240],
    }
    for key in ("trust_weighted_rating", "trust_score", "verified_authentic_percent"):
        if p.get(key) is not None:
            out[key] = p[key]
    return out


def _int(v: Any, default: int, lo: int, hi: int) -> int:
    try:
        return max(lo, min(hi, int(v)))
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# Tool model
# ---------------------------------------------------------------------------


@dataclass
class ToolDef:
    name: str
    title: str
    description: str
    scope: str
    handler: Handler
    properties: dict[str, Any] = field(default_factory=dict)
    required: list[str] = field(default_factory=list)
    read_only: bool = True
    destructive: bool = False
    idempotent: bool = True
    open_world: bool = False

    def input_schema(self) -> dict[str, Any]:
        return {
            "$schema": JSON_SCHEMA_DIALECT,
            "type": "object",
            "properties": self.properties,
            "required": self.required,
            "additionalProperties": False,
        }

    def descriptor(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "title": self.title,
            "description": self.description,
            "inputSchema": self.input_schema(),
            "annotations": {
                "title": self.title,
                "readOnlyHint": self.read_only,
                "destructiveHint": self.destructive,
                "idempotentHint": self.idempotent,
                "openWorldHint": self.open_world,
            },
            "_meta": {"penguin/requiredScope": self.scope, "penguin/backing": "supabase"},
        }


TOOLS: dict[str, ToolDef] = {}


def _register(tool: ToolDef) -> ToolDef:
    TOOLS[tool.name] = tool
    return tool


# ---------------------------------------------------------------------------
# Public read-only tools (catalog:read)
# ---------------------------------------------------------------------------


def _t_search_catalog(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    from app.agent.db_tools import search_products_db

    limit = _int(a.get("limit"), 8, 1, 24)
    query = str(a.get("query") or "").strip()
    rows = search_products_db(
        query=query,
        category=a.get("category"),
        max_price=a.get("max_price"),
        min_price=a.get("min_price"),
        only_3d=bool(a.get("only_3d", False)),
        in_stock_only=bool(a.get("in_stock_only", True)),
        occasion=a.get("occasion"),
        limit=limit,
    )
    engine = "sql_hybrid"
    rows = [r for r in rows if isinstance(r, dict) and is_product_active_row(r)]

    if not rows and query:
        try:
            from app.services.multimodal_search_service import execute_multimodal_rrf_search

            rrf = execute_multimodal_rrf_search(
                query_text=query,
                min_price=a.get("min_price"),
                max_price=a.get("max_price"),
                category=a.get("category"),
                only_3d=bool(a.get("only_3d", False)),
                limit=limit,
            )
            rows = [
                m["product"]
                for m in rrf.get("matches", [])
                if isinstance(m.get("product"), dict) and is_product_active_row(m["product"])
            ]
            engine = "rrf_fallback"
        except Exception as exc:
            logger.debug("MCP RRF fallback skipped: %s", exc)

    three_d = set(fetch_3d_catalog_ids_https())
    products = [_pub(r, three_d) for r in rows[:limit]]
    return {
        "query": query,
        "count": len(products),
        "engine": engine,
        "filters": {
            "category": a.get("category"),
            "min_price": a.get("min_price"),
            "max_price": a.get("max_price"),
            "only_3d": bool(a.get("only_3d", False)),
            "in_stock_only": bool(a.get("in_stock_only", True)),
            "occasion": a.get("occasion"),
        },
        "products": products,
    }


def _t_product_profile(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    from app.agent.db_tools import get_product_decision_profile

    pid = int(a["product_id"])
    prod = _active(pid)
    profile = _jsonable(get_product_decision_profile(pid))
    base = float(prod.get("price") or 0.0)
    category = str(prod.get("category") or "")

    profile["variants"] = variant_options(category, base)
    profile["add_ons"] = [dict(x) for x in ADDON_CATALOG]
    profile["b2b_moq_tiers"] = moq_tiers_for(base)
    profile["image_url"] = _abs_image(prod.get("image_url"))

    try:
        assets = fetch_product_3d_assets_https(pid)
    except Exception:
        assets = []
    profile["three_d"] = {
        "available": bool(assets),
        "models": [
            {
                "id": int(x.get("id") or 0),
                "display_name": x.get("display_name") or "3D View",
                "variant_name": x.get("variant_name"),
            }
            for x in assets
        ],
        "protected_reference_asset": pid == 144,
    }
    profile["product"] = _pub(prod, {pid} if assets else set())
    return profile


def _t_audit_reviews(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    from app.agent.db_tools import get_product_decision_profile
    from app.agent.tools import check_reviews_and_trust

    pid = int(a["product_id"])
    _active(pid)
    profile = _jsonable(get_product_decision_profile(pid))
    try:
        raw = check_reviews_and_trust.invoke({"product_id": pid})
        engine_report = json.loads(raw) if isinstance(raw, str) else (raw or {})
    except Exception:
        engine_report = {}
    return {
        "product_id": pid,
        "name": profile.get("name"),
        "trust_score": profile.get("trust_score"),
        "trust_weighted_rating": profile.get("trust_weighted_rating"),
        "average_rating": profile.get("average_rating"),
        "verified_authentic_percent": profile.get("verified_authentic_percent"),
        "review_count": profile.get("review_count"),
        "flagged_fake_review_count": profile.get("fake_review_count"),
        "verdict": profile.get("verdict"),
        "pros": profile.get("pros"),
        "cons": profile.get("cons"),
        "trust_engine_report": _jsonable(engine_report),
    }


def _t_compare(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    from app.agent.db_tools import compare_and_decide_best

    ids_raw = a.get("product_ids")
    ids: Optional[list[int]] = None
    if ids_raw:
        ids = []
        for x in ids_raw:
            if int(x) not in ids:
                ids.append(int(x))
        if len(ids) < 2 or len(ids) > 4:
            raise ToolExecutionError("Provide between 2 and 4 distinct product_ids to compare.")
        missing = [i for i in ids if fetch_product_by_id_https(i) is None]
        if missing:
            raise ToolExecutionError(f"Inactive or unknown product ids: {missing}.")
    elif not str(a.get("query") or "").strip():
        raise ToolExecutionError("Provide product_ids (2-4) or a search query to compare.")

    priority = str(a.get("priority") or "best_value")
    result = _jsonable(
        compare_and_decide_best(
            product_ids=ids,
            user_priority=priority,
            query=str(a.get("query") or ""),
            max_price=a.get("max_price"),
            only_3d=bool(a.get("only_3d", False)),
        )
    )
    result["scoring_dimensions"] = [
        "price_value",
        "trust_score",
        "stock",
        "feature_fit",
        "3d_support",
    ]
    result["priority"] = priority
    return result


def _t_pricing(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    pid = int(a["product_id"])
    quote = authoritative_deal_quote(
        pid,
        quantity=_int(a.get("quantity"), 1, 1, 1000),
        variant=a.get("variant"),
        gift_wrap=bool(a.get("gift_wrap", False)),
        warranty=bool(a.get("warranty", False)),
        promo_code=a.get("promo_code"),
    )
    if quote is None:
        raise ToolExecutionError(f"Product #{pid} was not found or is no longer active.")
    quote["moq_tiers"] = moq_tiers_for(quote["retail_unit_price"])
    return quote


def _t_list_3d(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    limit = _int(a.get("limit"), 12, 1, 50)
    showcase = fetch_3d_showcase_https()
    items = []
    for item in (showcase.get("items") or [])[:limit]:
        pub = _pub(item, {int(item["id"])})
        pub["models"] = item.get("models") or []
        pub["protected_reference_asset"] = int(item["id"]) == 144
        items.append(pub)
    return {"count": len(items), "total_available": showcase.get("count", len(items)), "items": items}


_register(
    ToolDef(
        name="search_catalog",
        title="Search Catalog",
        description=(
            "Search the live Penguin Store catalog (active products only) with hybrid SQL ranking, "
            "price/category/3D/stock filters and occasion expansion. Falls back to Reciprocal Rank "
            "Fusion text ranking when no direct match exists."
        ),
        scope=SCOPE_CATALOG_READ,
        handler=_t_search_catalog,
        properties={
            "query": {"type": "string", "maxLength": 200, "description": "Natural-language product query."},
            "category": {"type": "string", "maxLength": 60},
            "min_price": {"type": "number", "minimum": 0},
            "max_price": {"type": "number", "minimum": 0},
            "only_3d": {"type": "boolean", "description": "Only products with an interactive 3D .glb model."},
            "in_stock_only": {"type": "boolean", "description": "Defaults to true."},
            "occasion": {"type": "string", "maxLength": 60, "description": "e.g. party, gift, office."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 24},
        },
    )
)
_register(
    ToolDef(
        name="get_product_full_profile",
        title="Get Product Full Profile",
        description=(
            "Live product profile: specs, stock, editions/variants, add-ons, B2B MOQ tiers, "
            "3D .glb status, trust score and normalized image URL."
        ),
        scope=SCOPE_CATALOG_READ,
        handler=_t_product_profile,
        properties={"product_id": {"type": "integer", "minimum": 1}},
        required=["product_id"],
    )
)
_register(
    ToolDef(
        name="audit_product_reviews",
        title="Audit Product Reviews",
        description=(
            "AI Review Trust Engine report: trust score, trust-weighted rating, pros/cons/verdict, "
            "aspect sentiment and flagged fake review count for one product."
        ),
        scope=SCOPE_CATALOG_READ,
        handler=_t_audit_reviews,
        properties={"product_id": {"type": "integer", "minimum": 1}},
        required=["product_id"],
    )
)
_register(
    ToolDef(
        name="compare_and_score_products",
        title="Compare And Score Products",
        description=(
            "Score 2-4 live products on price value, trust, stock, feature fit and 3D support with "
            "transparent weighting for the chosen priority, and declare a verified winner."
        ),
        scope=SCOPE_CATALOG_READ,
        handler=_t_compare,
        properties={
            "product_ids": {
                "type": "array",
                "items": {"type": "integer"},
                "minItems": 2,
                "maxItems": 4,
            },
            "priority": {
                "type": "string",
                "enum": ["best_value", "highest_trust", "cheapest", "premium", "party", "bulk"],
            },
            "query": {"type": "string", "maxLength": 200, "description": "Used when product_ids is omitted."},
            "max_price": {"type": "number", "minimum": 0},
            "only_3d": {"type": "boolean"},
        },
    )
)
_register(
    ToolDef(
        name="calculate_pricing_and_deals",
        title="Calculate Pricing And Deals",
        description=(
            "Server-side B2C vs B2B MOQ pricing with variant/add-on fees, promo math and 5% tax. "
            "Uses the exact checkout engine; client-supplied prices are never trusted."
        ),
        scope=SCOPE_CATALOG_READ,
        handler=_t_pricing,
        properties={
            "product_id": {"type": "integer", "minimum": 1},
            "quantity": {"type": "integer", "minimum": 1, "maximum": 1000},
            "variant": {"type": "string", "maxLength": 120},
            "gift_wrap": {"type": "boolean"},
            "warranty": {"type": "boolean"},
            "promo_code": {"type": "string", "maxLength": 64},
        },
        required=["product_id"],
    )
)
_register(
    ToolDef(
        name="list_3d_showcase_models",
        title="List 3D Showcase Models",
        description="List active interactive 3D .glb catalog models (includes protected Product #144).",
        scope=SCOPE_CATALOG_READ,
        handler=_t_list_3d,
        properties={"limit": {"type": "integer", "minimum": 1, "maximum": 50}},
    )
)

# ---------------------------------------------------------------------------
# Authenticated commerce tools (commerce:write / b2b:write) — bound to principal.user_id
# ---------------------------------------------------------------------------


def _need(principal: Optional[Principal]) -> Principal:
    if principal is None:  # defensive; enforce_scope already blocks anonymous
        raise ToolExecutionError("Authentication required.")
    return principal


def _variant_key(variant: Optional[str], gift_wrap: bool, warranty: bool) -> str:
    parts = [(variant or "").strip()] if (variant or "").strip() else []
    if gift_wrap:
        parts.append("Gift Wrapping")
    if warranty:
        parts.append("Extended 2-Year Warranty")
    return " + ".join(parts)[:100]


def _cart_rows(user_id: int) -> list[dict[str, Any]]:
    res = (
        get_supabase_client()
        .table("cart_items")
        .select("product_id,quantity,selected_variant")
        .eq("user_id", user_id)
        .execute()
    )
    return list(res.data or [])


def _cart_view(user_id: int) -> dict[str, Any]:
    items: list[dict[str, Any]] = []
    subtotal = 0.0
    for row in _cart_rows(user_id):
        prod = fetch_product_by_id_https(int(row["product_id"]))
        if prod is None:  # inactive/deleted products never appear
            continue
        qty = int(row.get("quantity") or 1)
        line = round(float(prod.get("price") or 0.0) * qty, 2)
        subtotal += line
        items.append(
            {
                "product_id": int(prod["id"]),
                "name": prod.get("name"),
                "unit_price": round(float(prod.get("price") or 0.0), 2),
                "quantity": qty,
                "selected_variant": row.get("selected_variant") or "",
                "line_total": line,
                "stock": prod.get("stock"),
                "image_url": _abs_image(prod.get("image_url")),
            }
        )
    return {"items": items, "item_count": len(items), "subtotal": round(subtotal, 2)}


def _t_commerce_context(principal: Optional[Principal], _a: dict[str, Any]) -> dict[str, Any]:
    p = _need(principal)
    from app.api.v1.endpoints.commerce import _build_favorites_response
    from app.api.v1.endpoints.rfq import get_my_rfqs
    from app.routers.orders import get_order_history

    proxy = p.as_user_proxy()
    try:
        cart = _cart_view(p.user_id)
    except Exception as exc:
        logger.debug("MCP cart read fallback: %s", exc)
        cart = {"items": [], "item_count": 0, "subtotal": 0.0}
    try:
        favs = _build_favorites_response(p.user_id)
        favorites = [_pub(i) for i in favs.get("items", [])]
    except Exception:
        favorites = []
    try:
        history = get_order_history(customer_email=p.email, db=None, current_user=proxy)
        orders = [
            {
                "order_id": o.get("order_id"),
                "total_amount": o.get("total_amount"),
                "status": o.get("status") or o.get("payment_status"),
                "created_at": o.get("created_at"),
                "item_count": len(o.get("items") or []),
            }
            for o in (history.get("orders") or [])[:10]
        ]
    except Exception:
        orders = []
    try:
        rfq = get_my_rfqs(email=None, current_user=proxy)
        rfqs = [
            {
                "id": r["id"],
                "product_id": r["product_id"],
                "product_name": r["product_name"],
                "quantity": r["quantity"],
                "target_unit_price": r["target_unit_price"],
                "status": r["status"],
                "admin_quote_price": r["admin_quote_price"],
            }
            for r in (rfq.get("items") or [])[:10]
        ]
    except Exception:
        rfqs = []
    return _jsonable(
        {
            "user": {"id": p.user_id, "email": p.email, "role": p.role, "auth": p.auth_type},
            "cart": cart,
            "favorites": favorites,
            "recent_orders": orders,
            "b2b_rfqs": rfqs,
        }
    )


def _t_manage_cart(principal: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    from fastapi import HTTPException
    from app.core.supabase_rest import upsert_cart_item_atomic_sync

    p = _need(principal)
    action = str(a["action"]).lower()
    pid = int(a["product_id"])
    qty = _int(a.get("quantity"), 1, 1, 100)
    key = _variant_key(a.get("variant"), bool(a.get("gift_wrap")), bool(a.get("warranty")))
    client = get_supabase_client()

    if action in ("add", "update"):
        try:
            upsert_cart_item_atomic_sync(
                user_id=p.user_id,
                product_id=pid,
                quantity=qty,
                selected_variant=key,
                mode="set" if action == "update" else "increment",
            )
        except HTTPException as exc:
            raise ToolExecutionError(str(exc.detail))
    elif action == "remove":
        client.table("cart_items").delete().eq("user_id", p.user_id).eq(
            "product_id", pid
        ).eq("selected_variant", key).execute()
    else:
        raise ToolExecutionError("action must be one of add, update, remove.")

    return {"action": action, "product_id": pid, "variant": key, "cart": _cart_view(p.user_id)}


def _t_toggle_favorite(principal: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    p = _need(principal)
    from fastapi import HTTPException

    from app.api.v1.endpoints.commerce import (
        _add_user_favorite,
        _remove_user_favorite,
    )

    pid = int(a["product_id"])
    save = bool(a.get("save", True))
    try:
        if save:
            _active(pid)
            result = _add_user_favorite(p.user_id, pid)
        else:
            result = _remove_user_favorite(p.user_id, pid)
    except HTTPException as exc:
        raise ToolExecutionError(str(exc.detail))
    return {"product_id": pid, "saved": save, "favorite_product_ids": result.get("product_ids", [])}


def _t_submit_rfq(principal: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    p = _need(principal)
    from app.api.v1.endpoints.rfq import RFQCreateRequest, submit_rfq

    pid = int(a["product_id"])
    prod = _active(pid)
    qty = int(a["quantity"])
    if qty < 5:
        raise ToolExecutionError("B2B RFQs require a minimum order quantity (MOQ) of 5 units.")

    quote = authoritative_deal_quote(pid, quantity=qty, product_row=prod)
    target = a.get("target_unit_price")
    target_price = float(target) if target else float((quote or {}).get("b2b_unit_price") or prod["price"])
    if target_price <= 0:
        raise ToolExecutionError("target_unit_price must be greater than zero.")

    payload = RFQCreateRequest(
        product_id=pid,
        product_name=str(prod.get("name") or ""),
        customer_email=p.email,
        customer_name=p.email.split("@")[0],
        quantity=qty,
        target_unit_price=target_price,
        customization_notes=str(a.get("notes") or "")[:2000],
    )
    rfq = submit_rfq(payload=payload, current_user=p.as_user_proxy(), db=None)
    return {
        "rfq": _jsonable(rfq),
        "reference_wholesale_unit_price": (quote or {}).get("b2b_unit_price"),
        "moq_tier": (quote or {}).get("b2b_tier_label"),
        "status": "submitted",
    }


def _t_track_order(principal: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    p = _need(principal)
    from app.routers.orders import get_order_record

    oid = int(a["order_id"])
    record = get_order_record(oid)
    owner = str((record or {}).get("customer_email") or "").strip().lower()
    # Same message for "missing" and "someone else's" order: no existence oracle (anti-IDOR).
    if record is None or (owner != p.email and not p.is_admin):
        raise ToolExecutionError(f"Order #{oid} was not found for your account.")

    method = str(record.get("payment_method") or "COD").upper()
    pay_status = str(record.get("payment_status") or "").lower()
    if method == "STRIPE":
        verification = "stripe_verified" if pay_status == "paid" else "stripe_pending_payment"
    else:
        verification = "cod_confirmed"
    return _jsonable(
        {
            "order_id": oid,
            "status": record.get("status") or record.get("payment_status"),
            "payment_method": method,
            "payment_status": pay_status,
            "payment_verification": verification,
            "total_amount": record.get("total_amount"),
            "created_at": record.get("created_at"),
            "items": [
                {
                    "product_id": i.get("product_id"),
                    "name": i.get("product_name"),
                    "quantity": i.get("quantity"),
                    "unit_price": i.get("unit_price"),
                    "dispatch_status": i.get("dispatch_status"),
                    "tracking_number": i.get("tracking_number"),
                }
                for i in (record.get("items") or [])
            ],
        }
    )


_register(
    ToolDef(
        name="get_my_commerce_context",
        title="Get My Commerce Context",
        description="Read the caller's live cart, favorites, recent orders and B2B RFQs from Supabase.",
        scope=SCOPE_COMMERCE_WRITE,
        handler=_t_commerce_context,
    )
)
_register(
    ToolDef(
        name="manage_cart_item",
        title="Manage Cart Item",
        description=(
            "Add, update or remove an item in the caller's persistent Supabase cart with live stock "
            "validation. Only ever touches the authenticated caller's own cart."
        ),
        scope=SCOPE_COMMERCE_WRITE,
        read_only=False,
        destructive=False,
        idempotent=False,
        handler=_t_manage_cart,
        properties={
            "action": {"type": "string", "enum": ["add", "update", "remove"]},
            "product_id": {"type": "integer", "minimum": 1},
            "quantity": {"type": "integer", "minimum": 1, "maximum": 100},
            "variant": {"type": "string", "maxLength": 80},
            "gift_wrap": {"type": "boolean"},
            "warranty": {"type": "boolean"},
        },
        required=["action", "product_id"],
    )
)
_register(
    ToolDef(
        name="toggle_favorite_product",
        title="Toggle Favorite Product",
        description="Save or remove a product in the caller's persistent favorites (wishlist).",
        scope=SCOPE_COMMERCE_WRITE,
        read_only=False,
        idempotent=True,
        handler=_t_toggle_favorite,
        properties={
            "product_id": {"type": "integer", "minimum": 1},
            "save": {"type": "boolean", "description": "true = save, false = remove. Defaults to true."},
        },
        required=["product_id"],
    )
)
_register(
    ToolDef(
        name="submit_b2b_rfq",
        title="Submit B2B RFQ",
        description=(
            "Validate MOQ (min 5 units) and insert a real wholesale Request-For-Quote into Supabase "
            "`rfq_requests` for the caller. Defaults the target price to the authoritative B2B tier."
        ),
        scope=SCOPE_B2B_WRITE,
        read_only=False,
        idempotent=False,
        handler=_t_submit_rfq,
        properties={
            "product_id": {"type": "integer", "minimum": 1},
            "quantity": {"type": "integer", "minimum": 5, "maximum": 1000000},
            "target_unit_price": {"type": "number", "minimum": 0},
            "notes": {"type": "string", "maxLength": 2000},
        },
        required=["product_id", "quantity"],
    )
)
_register(
    ToolDef(
        name="track_my_order",
        title="Track My Order",
        description=(
            "Read the caller's live order status, payment verification (stripe/cod) and items. "
            "Orders belonging to other customers are never revealed."
        ),
        scope=SCOPE_COMMERCE_WRITE,
        handler=_t_track_order,
        properties={"order_id": {"type": "integer", "minimum": 1}},
        required=["order_id"],
    )
)

# ---------------------------------------------------------------------------
# Admin-only tools (admin:read)
# ---------------------------------------------------------------------------


def _t_admin_telemetry(_p: Optional[Principal], a: dict[str, Any]) -> dict[str, Any]:
    from app.mcp import audit
    from app.services import ai_telemetry_service as tele

    limit = _int(a.get("limit"), 25, 1, 100)
    ai_rows: list[dict[str, Any]] = []
    try:
        res = (
            get_supabase_client()
            .table("ai_metrics_logs")
            .select("subsystem,operation,latency_ms,success,created_at")
            .order("id", desc=True)
            .limit(300)
            .execute()
        )
        ai_rows = list(res.data or [])
    except Exception:
        ai_rows = list(tele._MEMORY_METRICS)[:300]  # noqa: SLF001

    by_subsystem: dict[str, dict[str, Any]] = {}
    for r in ai_rows:
        s = by_subsystem.setdefault(
            str(r.get("subsystem") or "unknown"), {"calls": 0, "ok": 0, "latency": 0.0}
        )
        s["calls"] += 1
        s["ok"] += 1 if r.get("success") else 0
        s["latency"] += float(r.get("latency_ms") or 0.0)
    ai_summary = {
        k: {
            "calls": v["calls"],
            "success_rate": round(v["ok"] / v["calls"] * 100, 2),
            "avg_latency_ms": round(v["latency"] / v["calls"], 2),
        }
        for k, v in by_subsystem.items()
    }
    return _jsonable(
        {
            "ai_subsystems": ai_summary,
            "mcp": audit.summarize(include_recent=True, recent_limit=limit),
        }
    )


def _t_pending_rfqs(principal: Optional[Principal], _a: dict[str, Any]) -> dict[str, Any]:
    from app.api.v1.endpoints.rfq import list_admin_rfqs

    admin = _need(principal)
    result = list_admin_rfqs(status_filter="Pending", admin_user=admin.as_user_proxy())
    return _jsonable({"count": result.get("count", 0), "items": result.get("items", [])})


_register(
    ToolDef(
        name="get_store_ai_telemetry",
        title="Get Store AI Telemetry",
        description="Admin only: live AI + MCP latency, success rate and tool analytics.",
        scope=SCOPE_ADMIN_READ,
        handler=_t_admin_telemetry,
        properties={"limit": {"type": "integer", "minimum": 1, "maximum": 100}},
    )
)
_register(
    ToolDef(
        name="list_pending_b2b_rfqs",
        title="List Pending B2B RFQs",
        description="Admin only: wholesale Requests-For-Quote awaiting review.",
        scope=SCOPE_ADMIN_READ,
        handler=_t_pending_rfqs,
    )
)

# ---------------------------------------------------------------------------
# Tool invocation
# ---------------------------------------------------------------------------


def list_tools() -> list[dict[str, Any]]:
    return [t.descriptor() for t in TOOLS.values()]


def call_tool(
    name: str,
    arguments: Optional[dict[str, Any]],
    principal: Optional[Principal],
) -> dict[str, Any]:
    """Execute a tool and return an MCP CallToolResult. Protocol failures raise MCPError."""
    tool = TOOLS.get(name)
    if tool is None:
        raise MCPError(INVALID_PARAMS, f"Unknown tool: {name}", http_status=200)

    args = arguments or {}
    if not isinstance(args, dict):
        raise MCPError(INVALID_PARAMS, "Tool arguments must be an object.")

    enforce_scope(principal, tool.scope, tool.read_only)

    problems = validate_arguments(tool.input_schema(), args)
    if problems:
        raise MCPError(INVALID_PARAMS, "Invalid tool arguments.", data={"problems": problems})

    try:
        structured = _jsonable(tool.handler(principal, args))
        return {
            "content": [{"type": "text", "text": json.dumps(structured, ensure_ascii=False)}],
            "structuredContent": structured,
            "isError": False,
        }
    except ToolExecutionError as exc:
        return {
            "content": [{"type": "text", "text": str(exc)}],
            "structuredContent": {"error": str(exc)},
            "isError": True,
        }
    except MCPError:
        raise
    except Exception:
        logger.exception("MCP tool %s failed", name)
        msg = "The tool failed unexpectedly. Please try again."
        return {
            "content": [{"type": "text", "text": msg}],
            "structuredContent": {"error": msg},
            "isError": True,
        }


def invoke_internal(
    name: str,
    arguments: Optional[dict[str, Any]] = None,
    *,
    source: str = "ctrl-x",
    principal: Optional[Principal] = None,
) -> dict[str, Any]:
    """In-process entry used by CTRL-X / Voice Concierge. Returns the structured payload.

    Executes the identical registry handler external MCP clients hit, and writes an audit
    row tagged with `source` so Admin telemetry shows who used which tool.
    """
    import time

    from app.mcp import audit

    started = time.perf_counter()
    ok = True
    code: Optional[int] = None
    try:
        result = call_tool(name, arguments, principal)
        if result.get("isError"):
            ok = False
            raise ToolExecutionError(str(result["structuredContent"].get("error")))
        return result["structuredContent"]
    except MCPError as exc:
        ok, code = False, exc.code
        raise ToolExecutionError(exc.message) from exc
    except ToolExecutionError:
        ok = False
        raise
    finally:
        try:
            audit.log_call(
                {
                    "source": source,
                    "method": "tools/call",
                    "tool_name": name,
                    "protocol_version": LATEST_VERSION,
                    "principal_type": principal.auth_type if principal else "anonymous",
                    "user_id": principal.user_id if principal else None,
                    "latency_ms": (time.perf_counter() - started) * 1000.0,
                    "success": ok,
                    "error_code": code,
                }
            )
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Resources & templates
# ---------------------------------------------------------------------------

RESOURCES: list[dict[str, Any]] = [
    {
        "uri": "penguin://store/manifest",
        "name": "store-manifest",
        "title": "Penguin Store Manifest",
        "description": "Live store capabilities, counts and MCP endpoints.",
        "mimeType": "application/json",
    },
    {
        "uri": "penguin://catalog/categories",
        "name": "catalog-categories",
        "title": "Catalog Categories",
        "description": "Active product categories with live counts.",
        "mimeType": "application/json",
    },
    {
        "uri": "penguin://catalog/3d-showcase",
        "name": "catalog-3d-showcase",
        "title": "3D Showcase",
        "description": "Active interactive 3D .glb models.",
        "mimeType": "application/json",
    },
    {
        "uri": "penguin://b2b/moq-policy",
        "name": "b2b-moq-policy",
        "title": "B2B MOQ & Pricing Policy",
        "description": "Wholesale tiers, RFQ minimums, promo codes and tax.",
        "mimeType": "application/json",
    },
]

RESOURCE_TEMPLATES: list[dict[str, Any]] = [
    {
        "uriTemplate": "penguin://products/{product_id}",
        "name": "product",
        "title": "Product",
        "description": "Full live profile of one active product.",
        "mimeType": "application/json",
    },
    {
        "uriTemplate": "penguin://products/{product_id}/trust-report",
        "name": "product-trust-report",
        "title": "Product Trust Report",
        "description": "AI Review Trust Engine report for one product.",
        "mimeType": "application/json",
    },
]

_PRODUCT_URI = re.compile(r"^penguin://products/(\d+)(/trust-report)?$")


def _not_found(uri: str, version: str) -> MCPError:
    # 2026-07-28 uses -32602 for resource-not-found; -32002 only in 2025-11-25 mode.
    code = INVALID_PARAMS if version == LATEST_VERSION else RESOURCE_NOT_FOUND_LEGACY
    return MCPError(code, f"Resource not found: {uri}", data={"uri": uri})


def read_resource(uri: str, version: str) -> dict[str, Any]:
    payload: Any
    if uri == "penguin://store/manifest":
        products = fetch_products_https()
        payload = {
            "name": SERVER_TITLE,
            "mcp": {"versions": [LATEST_VERSION, LEGACY_VERSION], "endpoint": f"{PUBLIC_API_BASE}/mcp"},
            "active_products": len(products),
            "categories": len({str(p.get("category") or "") for p in products}),
            "interactive_3d_models": len(fetch_3d_catalog_ids_https()),
            "features": [
                "CTRL-X multi-agent assistant",
                "Penguin Voice Concierge",
                "Multimodal RRF search",
                "Review Trust Engine",
                "Interactive 3D showcase",
                "B2C variants, add-ons, coupons",
                "B2B MOQ & RFQ",
                "Stripe Checkout + COD",
            ],
            "tools": sorted(TOOLS),
        }
    elif uri == "penguin://catalog/categories":
        counts: dict[str, int] = {}
        for p in fetch_products_https():
            cat = str(p.get("category") or "Uncategorized")
            counts[cat] = counts.get(cat, 0) + 1
        payload = {
            "categories": [
                {"category": c, "active_products": n}
                for c, n in sorted(counts.items(), key=lambda kv: -kv[1])
            ]
        }
    elif uri == "penguin://catalog/3d-showcase":
        payload = _t_list_3d(None, {"limit": 50})
    elif uri == "penguin://b2b/moq-policy":
        payload = {
            "tiers": list(MOQ_TIERS),
            "rfq_minimum_units": 5,
            "promo_codes": list(PROMO_CODES),
            "tax_rate_percent": 5,
            "add_ons": list(ADDON_CATALOG),
            "note": "All prices are recalculated server-side at checkout; quotes from MCP match exactly.",
        }
    else:
        match = _PRODUCT_URI.match(uri)
        if not match:
            raise _not_found(uri, version)
        pid = int(match.group(1))
        try:
            payload = (
                _t_audit_reviews(None, {"product_id": pid})
                if match.group(2)
                else _t_product_profile(None, {"product_id": pid})
            )
        except ToolExecutionError:
            raise _not_found(uri, version)

    return {
        "contents": [
            {
                "uri": uri,
                "mimeType": "application/json",
                "text": json.dumps(_jsonable(payload), ensure_ascii=False),
            }
        ]
    }


# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

PROMPTS: dict[str, dict[str, Any]] = {
    "budget_bundle_architect": {
        "title": "Budget Bundle Architect",
        "description": "Build a trust-verified gift/party bundle that stays inside a budget.",
        "arguments": [
            {"name": "occasion", "description": "e.g. birthday party", "required": True},
            {"name": "max_budget", "description": "Maximum total in USD", "required": True},
        ],
        "template": (
            "Act as a Penguin Store shopping agent. Build a bundle for '{occasion}' with a hard budget "
            "of ${max_budget} total.\n1. Call search_catalog (use the occasion filter, in_stock_only=true) "
            "several times across different categories.\n2. Call audit_product_reviews on the finalists and "
            "drop anything with a low trust score.\n3. Call calculate_pricing_and_deals for the final set.\n"
            "4. Present the bundle with total cost, savings and why each item was chosen. Never exceed the budget."
        ),
    },
    "trust_verified_comparison": {
        "title": "Trust-Verified Comparison",
        "description": "Compare the best products for a query using real review trust data.",
        "arguments": [
            {"name": "category_or_query", "description": "What to compare", "required": True},
            {"name": "priority", "description": "best_value | highest_trust | cheapest | premium", "required": False},
        ],
        "template": (
            "Compare the best '{category_or_query}' products in Penguin Store with priority '{priority}'.\n"
            "1. search_catalog to find 3-4 candidates.\n2. compare_and_score_products on their ids.\n"
            "3. audit_product_reviews on the winner and runner-up.\n4. Explain the verified winner, the "
            "trade-offs, and flag any fake-review risk."
        ),
    },
    "b2b_wholesale_procurement_brief": {
        "title": "B2B Wholesale Procurement Brief",
        "description": "Prepare a wholesale procurement recommendation and RFQ.",
        "arguments": [
            {"name": "product_query", "description": "Product to buy in bulk", "required": True},
            {"name": "quantity", "description": "Units required", "required": True},
        ],
        "template": (
            "Prepare a B2B procurement brief for {quantity} units of '{product_query}'.\n"
            "1. search_catalog for the best match.\n2. calculate_pricing_and_deals with quantity={quantity} "
            "to show the MOQ tier and total.\n3. If the caller is authenticated, offer to file the quote "
            "with submit_b2b_rfq (minimum 5 units).\n4. Summarize unit price, total, savings and lead risks."
        ),
    },
    "explore_3d_flagships": {
        "title": "Explore 3D Flagships",
        "description": "Showcase the best interactive 3D products.",
        "arguments": [],
        "template": (
            "Tour Penguin Store's interactive 3D catalog.\n1. list_3d_showcase_models.\n"
            "2. get_product_full_profile for the top three.\n3. Recommend which 3D product to open first "
            "and explain what the 3D twin lets a shopper inspect. Product #144 is the reference showcase."
        ),
    },
}


def list_prompts() -> list[dict[str, Any]]:
    return [
        {
            "name": name,
            "title": spec["title"],
            "description": spec["description"],
            "arguments": spec["arguments"],
        }
        for name, spec in PROMPTS.items()
    ]


def get_prompt(name: str, arguments: Optional[dict[str, Any]]) -> dict[str, Any]:
    spec = PROMPTS.get(name)
    if spec is None:
        raise MCPError(INVALID_PARAMS, f"Unknown prompt: {name}")
    args = {k: str(v) for k, v in (arguments or {}).items()}
    for arg in spec["arguments"]:
        if arg["required"] and not args.get(arg["name"], "").strip():
            raise MCPError(INVALID_PARAMS, f'Missing required prompt argument "{arg["name"]}".')
    args.setdefault("priority", "best_value")

    class _Safe(dict):
        def __missing__(self, key: str) -> str:
            return ""

    text = spec["template"].format_map(_Safe(args))
    return {
        "description": spec["description"],
        "messages": [{"role": "user", "content": {"type": "text", "text": text}}],
    }
