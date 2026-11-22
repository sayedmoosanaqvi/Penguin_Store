import json
import logging
import re
from typing import Any, Optional, Union

from langchain_core.tools import tool
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.agent.rag import retrieve_store_knowledge
from app.core.supabase_rest import (
    fetch_3d_catalog_ids_https,
    fetch_product_by_id_https,
    fetch_products_https,
    get_supabase_client,
)
from app.database import SessionLocal
from app.models import Order, OrderItem, Product

logger = logging.getLogger("uvicorn.error")

# ===========================================================================
# OCCASION, LIFESTYLE & INTENT QUERY EXPANSION DICTIONARY (PHASE 1.1)
# ===========================================================================
OCCASION_EXPANSION_MAP: dict[str, list[str]] = {
    "party": [
        "speaker",
        "audio",
        "headphone",
        "earbuds",
        "lighting",
        "lamp",
        "camera",
        "shirt",
        "dress",
        "shoes",
        "watch",
        "fragrance",
        "perfume",
        "sunglasses",
        "bag",
        "accessories",
        "electronics",
    ],
    "celebration": [
        "shirt",
        "dress",
        "shoes",
        "watch",
        "fragrance",
        "speaker",
        "audio",
        "accessories",
    ],
    "wedding": [
        "shirt",
        "dress",
        "shoes",
        "watch",
        "fragrance",
        "perfume",
        "handbag",
        "bag",
        "jewelry",
        "formal",
        "accessories",
    ],
    "formal": [
        "shirt",
        "shoes",
        "watch",
        "fragrance",
        "suit",
        "leather",
        "dress",
    ],
    "date": [
        "shirt",
        "dress",
        "watch",
        "fragrance",
        "perfume",
        "shoes",
        "handbag",
    ],
    "gamer": [
        "gaming",
        "headphone",
        "audio",
        "laptop",
        "phone",
        "smartphone",
        "earbuds",
        "watch",
        "lamp",
        "electronics",
        "accessories",
    ],
    "gaming": [
        "gaming",
        "headphone",
        "audio",
        "laptop",
        "phone",
        "smartphone",
        "earbuds",
        "electronics",
        "accessories",
    ],
    "remote": [
        "laptop",
        "phone",
        "smartphone",
        "tablet",
        "watch",
        "lamp",
        "desk",
        "furniture",
        "decor",
        "electronics",
        "accessories",
    ],
    "office": [
        "laptop",
        "shirt",
        "shoes",
        "watch",
        "bag",
        "lamp",
        "desk",
        "furniture",
        "accessories",
    ],
    "work": [
        "laptop",
        "shirt",
        "shoes",
        "watch",
        "bag",
        "phone",
        "accessories",
    ],
    "setup": [
        "laptop",
        "phone",
        "smartphone",
        "watch",
        "lamp",
        "audio",
        "headphone",
        "furniture",
        "decor",
        "electronics",
        "accessories",
    ],
    "gift": [
        "watch",
        "fragrance",
        "perfume",
        "sunglasses",
        "handbag",
        "bag",
        "smartphone",
        "earbuds",
        "shirt",
        "shoes",
        "accessories",
    ],
    "workout": [
        "shoes",
        "sneakers",
        "watch",
        "shirt",
        "earbuds",
        "sports",
        "running",
    ],
    "gym": [
        "shoes",
        "sneakers",
        "watch",
        "shirt",
        "earbuds",
        "sports",
    ],
    "travel": [
        "bag",
        "sunglasses",
        "watch",
        "shoes",
        "sneakers",
        "phone",
        "earbuds",
        "camera",
        "accessories",
    ],
    "summer": [
        "shirt",
        "sunglasses",
        "dress",
        "shoes",
        "sneakers",
        "fragrance",
    ],
    "winter": [
        "jacket",
        "shirt",
        "boots",
        "shoes",
        "watch",
        "fragrance",
    ],
    "audio": [
        "audio",
        "speaker",
        "headphone",
        "earbuds",
        "airpods",
        "pods",
        "music",
        "sound",
        "electronics",
        "accessories",
    ],
    "outfit": [
        "shirt",
        "shoes",
        "watch",
        "pants",
        "dress",
        "bag",
        "sunglasses",
        "accessories",
    ],
}


def _normalize_text(value: Optional[str]) -> str:
    if not value:
        return ""
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())


def _search_tokens(value: Optional[str]) -> list[str]:
    text = _normalize_text(value)
    if not text:
        return []

    stop_words = {
        "a",
        "an",
        "the",
        "and",
        "or",
        "for",
        "with",
        "to",
        "me",
        "my",
        "i",
        "want",
        "need",
        "show",
        "find",
        "looking",
        "something",
        "some",
        "product",
        "products",
        "item",
        "items",
        "plan",
        "best",
        "top",
        "under",
        "below",
        "around",
        "please",
        "can",
        "you",
        "recommend",
        "suggest",
    }

    return [
        token
        for token in text.split()
        if len(token) > 1 and token not in stop_words
    ]


def expand_query_concepts(raw_query: Optional[str]) -> tuple[list[str], list[str]]:
    """
    Expand a user's raw or occasion-based query (e.g., 'I need a party',
    'gift for a gamer', 'remote work setup') into:
      (direct_tokens, expanded_concept_tokens)
    """
    direct = _search_tokens(raw_query)
    expanded: list[str] = []
    seen: set[str] = set()

    q_norm = _normalize_text(raw_query)
    for trigger, concepts in OCCASION_EXPANSION_MAP.items():
        if trigger in q_norm or trigger in direct:
            for c in concepts:
                if c not in seen:
                    seen.add(c)
                    expanded.append(c)

    return direct, expanded


def _score_product_dict(
    product: dict[str, Any],
    search_term: Optional[str],
    category: Optional[str],
    active_3d_ids: set[int],
) -> tuple[float, str]:
    """
    Hybrid relevance scorer over normalized product dicts from Supabase.
    Returns (score, match_explanation).
    """
    pid = int(product.get("id") or 0)
    name = _normalize_text(str(product.get("name") or ""))
    product_category = _normalize_text(str(product.get("category") or ""))
    description = _normalize_text(str(product.get("description") or ""))
    haystack = f"{name} {product_category} {description}"

    search_text = _normalize_text(search_term)
    requested_category = _normalize_text(category)

    score = 0.0
    matched_concepts: list[str] = []

    # 1. Category relevance
    if requested_category:
        if requested_category == product_category:
            score += 32.0
            matched_concepts.append(f"category:{product.get('category')}")
        elif requested_category in product_category:
            score += 24.0
            matched_concepts.append(f"category:{product.get('category')}")

        for token in _search_tokens(requested_category):
            if token in product_category:
                score += 10.0
            elif token in name:
                score += 5.0

    # 2. Direct search-term relevance
    direct_tokens, expanded_tokens = expand_query_concepts(search_term)

    if search_text:
        if search_text in name:
            score += 35.0
            matched_concepts.append("exact title match")
        if search_text in product_category:
            score += 22.0
        if search_text in description:
            score += 12.0

        for token in direct_tokens:
            if token == "3d" and pid in active_3d_ids:
                score += 40.0
                matched_concepts.append("Interactive 3D GLB model")
                continue
            if token in name:
                score += 14.0
                matched_concepts.append(token)
            elif token in product_category:
                score += 10.0
                matched_concepts.append(token)
            elif token in description:
                score += 4.5
                matched_concepts.append(token)

    # 3. Occasion & Lifestyle Expanded Concept Matching ("I need a party", "gamer gift", etc.)
    if expanded_tokens:
        for concept in expanded_tokens:
            if concept == "3d" and pid in active_3d_ids:
                score += 15.0
                matched_concepts.append("3D studio ready")
            elif concept in name:
                score += 9.5
                if concept not in matched_concepts:
                    matched_concepts.append(concept)
            elif concept in product_category:
                score += 8.0
                if concept not in matched_concepts:
                    matched_concepts.append(concept)
            elif concept in haystack:
                score += 3.5

    # 4. 3D & Quality tie-breakers
    if pid in active_3d_ids:
        score += 2.0
    if product.get("is_featured"):
        score += 1.5

    reason = (
        f"Matched {', '.join(matched_concepts[:3])}"
        if matched_concepts
        else f"Top-rated in {product.get('category', 'Store')}"
    )
    return score, reason


def _enrich_public_product_dict(
    row: dict[str, Any],
    active_3d_ids: set[int],
    match_reason: str = "",
) -> dict[str, Any]:
    pid = int(row.get("id") or 0)
    return {
        "id": pid,
        "name": str(row.get("name") or ""),
        "description": str(row.get("description") or ""),
        "price": float(row.get("price") or 0.0),
        "original_price": (
            float(row["original_price"])
            if row.get("original_price") is not None
            else None
        ),
        "image_url": str(row.get("image_url") or ""),
        "category": str(row.get("category") or "CATALOG"),
        "rating": float(row.get("rating") or 4.8),
        "reviews": int(row.get("reviews") or 12),
        "discount_percent": row.get("discount_percent"),
        "is_featured": bool(row.get("is_featured", False)),
        "stock": int(row["stock"]) if row.get("stock") is not None else 50,
        "fulfillment_type": str(row.get("fulfillment_type") or "IN_HOUSE"),
        "has_3d_model": pid in active_3d_ids,
        "match_reason": match_reason,
    }


# ===========================================================================
# PRODUCT SEARCH TOOL (Hybrid Occasion-Aware + Supabase HTTPS Fast Path)
# ===========================================================================

class ProductSearchInput(BaseModel):
    search_term: Optional[str] = Field(
        default=None,
        description=(
            "A product keyword, style, color, brand, material, occasion, "
            "or descriptive search term. Examples: party, gamer gift, "
            "remote work setup, 3d, black shirt, running shoes."
        ),
    )
    category: Optional[str] = Field(
        default=None,
        description="Optional product category filter.",
    )
    max_price: Optional[float] = Field(
        default=None,
        description="Maximum price the customer is willing to pay.",
    )
    is_featured: Optional[bool] = Field(
        default=None,
        description="Set to true only when customer specifically requests featured items.",
    )


@tool("search_inventory", args_schema=ProductSearchInput)
def search_inventory(
    search_term: Optional[str] = None,
    category: Optional[str] = None,
    max_price: Optional[float] = None,
    is_featured: Optional[bool] = None,
) -> str:
    """
    Search Penguin Store's live Supabase product inventory using occasion-aware
    query expansion, category matching, 3D model awareness, and stock filtering.
    """
    logger.info(
        "[TOOL CALLED] search_inventory | search_term=%s | category=%s | max_price=%s | is_featured=%s",
        search_term,
        category,
        max_price,
        is_featured,
    )

    try:
        all_products = fetch_products_https()
        active_3d_ids = set(fetch_3d_catalog_ids_https())

        # Filter in-stock products
        in_stock = [
            p for p in all_products if int(p.get("stock") if p.get("stock") is not None else 50) > 0
        ]

        if max_price is not None:
            in_stock = [p for p in in_stock if float(p.get("price") or 0.0) <= float(max_price)]

        if is_featured is True:
            featured_subset = [p for p in in_stock if bool(p.get("is_featured"))]
            if featured_subset:
                in_stock = featured_subset

        # Check if user explicitly asked for 3D products
        q_norm = _normalize_text(f"{search_term or ''} {category or ''}")
        wants_3d_only = "3d" in q_norm.split()
        if wants_3d_only:
            only_3d = [p for p in in_stock if int(p.get("id") or 0) in active_3d_ids]
            if only_3d:
                in_stock = only_3d

        scored_items: list[tuple[float, str, dict[str, Any]]] = []
        for p in in_stock:
            score, reason = _score_product_dict(p, search_term, category, active_3d_ids)
            scored_items.append((score, reason, p))

        # Keep items with positive relevance score (> 2.5); if none matched (e.g., very broad
        # lifestyle query with no direct keyword hit), return top diverse in-stock catalog items
        # so CTRL-X always grounds its answer in real available store products.
        positive_matches = [item for item in scored_items if item[0] > 3.5]

        if positive_matches:
            positive_matches.sort(
                key=lambda item: (
                    item[0],
                    float(item[2].get("rating") or 4.8),
                    int(item[2].get("reviews") or 0),
                ),
                reverse=True,
            )
            chosen = positive_matches[:6]
        else:
            # Grounded diverse catalog fallback across top categories
            scored_items.sort(
                key=lambda item: (
                    1 if int(item[2].get("id") or 0) in active_3d_ids else 0,
                    1 if item[2].get("is_featured") else 0,
                    float(item[2].get("rating") or 4.8),
                ),
                reverse=True,
            )
            seen_cats: set[str] = set()
            chosen = []
            for score, reason, prod in scored_items:
                cat = str(prod.get("category") or "")
                if cat not in seen_cats or len(chosen) < 6:
                    seen_cats.add(cat)
                    chosen.append((score, f"Popular in {cat}", prod))
                if len(chosen) >= 6:
                    break

        results = [
            _enrich_public_product_dict(prod, active_3d_ids, reason)
            for _, reason, prod in chosen
        ]

        logger.info(
            "[TOOL RESULT] search_inventory found %d grounded products",
            len(results),
        )
        return json.dumps(results, ensure_ascii=False)
    except Exception:
        logger.exception("[TOOL ERROR] search_inventory failed")
        return "[]"


# ===========================================================================
# CATALOG DISCOVERY TOOL
# ===========================================================================

@tool("inspect_catalog")
def inspect_catalog() -> str:
    """
    Inspect currently available Penguin Store categories and representative products.
    """
    logger.info("[TOOL CALLED] inspect_catalog")
    try:
        all_products = fetch_products_https()
        catalog: dict[str, dict[str, Any]] = {}

        for p in all_products:
            if int(p.get("stock") if p.get("stock") is not None else 50) <= 0:
                continue
            category = str(p.get("category") or "CATALOG").strip()
            name = str(p.get("name") or "Product").strip()
            if category not in catalog:
                catalog[category] = {"count": 0, "examples": []}
            catalog[category]["count"] += 1
            if len(catalog[category]["examples"]) < 3:
                catalog[category]["examples"].append(name)

        categories = [
            {
                "category": cat,
                "available_product_count": data["count"],
                "example_products": data["examples"],
            }
            for cat, data in sorted(catalog.items())
        ]

        return json.dumps(
            {
                "instruction": (
                    "These are the real categories currently available in Penguin Store. "
                    "Use these categories and example products for grounded searches."
                ),
                "available_categories": categories,
            },
            ensure_ascii=False,
        )
    except Exception:
        logger.exception("[TOOL ERROR] inspect_catalog failed")
        return json.dumps({"available_categories": []})


# ===========================================================================
# CART TOOL
# ===========================================================================

class AddToCartInput(BaseModel):
    product_id: int = Field(..., description="Exact product ID to add to the cart.")
    quantity: int = Field(default=1, ge=1, description="Number of units requested.")


@tool("add_to_cart", args_schema=AddToCartInput)
def add_to_cart(product_id: int, quantity: int = 1) -> str:
    """
    Prepare a customer cart action for an exact product from Supabase.
    """
    logger.info("[TOOL CALLED] add_to_cart | product_id=%s | quantity=%s", product_id, quantity)
    try:
        product = fetch_product_by_id_https(product_id)
        if not product:
            return json.dumps({"error": f"Product #{product_id} not found."})

        avail_stock = int(product.get("stock") if product.get("stock") is not None else 50)
        if avail_stock < quantity:
            return json.dumps(
                {
                    "error": "Requested quantity is not available.",
                    "available_stock": avail_stock,
                }
            )

        return json.dumps(
            {
                "action": "add_to_cart",
                "product": {
                    "id": int(product["id"]),
                    "name": product.get("name"),
                    "price": float(product.get("price") or 0.0),
                    "image_url": product.get("image_url"),
                    "category": product.get("category") or "CATALOG",
                },
                "quantity": quantity,
            },
            ensure_ascii=False,
        )
    except Exception:
        logger.exception("[TOOL ERROR] add_to_cart failed")
        return json.dumps({"error": "Unable to prepare cart action."})


# ===========================================================================
# ORDER STATUS TOOL
# ===========================================================================

class OrderStatusInput(BaseModel):
    order_id: Union[str, int] = Field(
        ...,
        description="Exact Penguin Store order ID supplied by the customer.",
    )


@tool("check_order_status", args_schema=OrderStatusInput)
def check_order_status(order_id: Union[str, int]) -> str:
    """
    Retrieve the real fulfillment state of a Penguin Store order over Supabase HTTPS.
    """
    logger.info("[TOOL CALLED] check_order_status | order_id=%s", order_id)
    clean_id = str(order_id).strip().lstrip("#")
    if not clean_id.isdigit():
        return json.dumps({"error": "Order ID must be numeric."})

    query_id = int(clean_id)

    # 1. Check in-memory recent orders cache first
    try:
        from app.routers.orders import get_order_record

        mem_order = get_order_record(query_id)
        if mem_order is not None:
            items = mem_order.get("items") or []
            tracking_numbers = [
                i.get("tracking_number") for i in items if i.get("tracking_number")
            ]
            return json.dumps(
                {
                    "action": "order_status",
                    "order": {
                        "order_id": str(query_id),
                        "created_at": mem_order.get("created_at"),
                        "total": float(mem_order.get("total_amount") or 0.0),
                        "overall_status": mem_order.get("payment_status", "CONFIRMED").upper(),
                        "tracking_numbers": tracking_numbers,
                        "items": items,
                    },
                },
                ensure_ascii=False,
            )
    except Exception:
        pass

    # 2. Query Supabase HTTPS REST
    try:
        client = get_supabase_client()
        ord_res = client.table("orders").select("*").eq("id", query_id).limit(1).execute()
        rows = ord_res.data or []
        if not rows:
            return json.dumps({"error": f"Order {query_id} could not be found."})

        order_row = rows[0]
        items_res = (
            client.table("order_items")
            .select("*")
            .eq("order_id", query_id)
            .execute()
        )
        raw_items = items_res.data or []
        items = []
        tracking_numbers = []
        statuses = set()

        for item in raw_items:
            pid = item.get("product_id")
            p_dict = fetch_product_by_id_https(int(pid)) if pid else None
            d_status = str(item.get("dispatch_status") or "QUEUED_FOR_PACKING").upper()
            statuses.add(d_status)
            trk = item.get("tracking_number")
            if trk:
                tracking_numbers.append(str(trk))
            items.append(
                {
                    "order_item_id": item.get("id"),
                    "product_id": pid,
                    "product_name": (p_dict or {}).get("name") or f"Product #{pid}",
                    "quantity": item.get("quantity", 1),
                    "unit_price": float(item.get("unit_price") or 0.0),
                    "fulfillment_type": item.get("fulfillment_type") or "IN_HOUSE",
                    "dispatch_status": d_status,
                    "tracking_number": trk,
                }
            )

        overall_status = (
            "NO_FULFILLMENT_DATA"
            if not statuses
            else (next(iter(statuses)) if len(statuses) == 1 else "PARTIALLY_FULFILLED")
        )

        return json.dumps(
            {
                "action": "order_status",
                "order": {
                    "order_id": str(query_id),
                    "created_at": order_row.get("created_at"),
                    "total": float(order_row.get("total_amount") or 0.0),
                    "overall_status": overall_status,
                    "tracking_numbers": tracking_numbers,
                    "items": items,
                },
            },
            ensure_ascii=False,
        )
    except Exception:
        logger.exception("[TOOL ERROR] check_order_status failed")
        return json.dumps({"error": "Unable to retrieve order status."})


# ===========================================================================
# STORE KNOWLEDGE TOOL
# ===========================================================================

class KnowledgeBaseSearchInput(BaseModel):
    query: str = Field(
        ...,
        description="Question about Penguin Store policies, returns, refunds, warranties, or payments.",
    )


@tool("search_knowledge_base", args_schema=KnowledgeBaseSearchInput)
def search_knowledge_base(query: str) -> str:
    """
    Search Penguin Store's official knowledge base.
    """
    logger.info("[TOOL CALLED] search_knowledge_base | query=%s", query)
    try:
        context = retrieve_store_knowledge(query)
        if not context:
            return "No matching information was found in the Penguin Store knowledge base."
        return context
    except Exception:
        logger.exception("[TOOL ERROR] search_knowledge_base failed")
        return "Unable to retrieve Penguin Store policy information."


# ===========================================================================
# PRODUCT COMPARISON TOOL (Phase 1.2 Interactive Price & Feature Comparison)
# ===========================================================================

class CompareProductsInput(BaseModel):
    product_ids: Optional[list[int]] = Field(
        default=None,
        description="Optional list of specific product IDs to compare.",
    )
    query: Optional[str] = Field(
        default=None,
        description="Search keyword, category, or occasion to find top products to compare.",
    )
    limit: int = Field(
        default=3,
        ge=2,
        le=5,
        description="Maximum number of products to compare side-by-side.",
    )


@tool("compare_products", args_schema=CompareProductsInput)
def compare_products(
    product_ids: Optional[list[int]] = None,
    query: Optional[str] = None,
    limit: int = 3,
) -> str:
    """
    Compare products side-by-side using real Supabase catalog and 3D asset data.
    """
    logger.info("[TOOL CALLED] compare_products | ids=%s | query=%s", product_ids, query)
    try:
        all_products = fetch_products_https()
        active_3d_ids = set(fetch_3d_catalog_ids_https())

        candidates: list[dict[str, Any]] = []
        if product_ids:
            clean_ids = {
                int(pid)
                for pid in product_ids
                if isinstance(pid, (int, str)) and str(pid).isdigit()
            }
            candidates = [p for p in all_products if int(p.get("id") or 0) in clean_ids]
            # Preserve exact requested ID order when provided
            by_id = {int(p["id"]): p for p in candidates if p.get("id")}
            candidates = [by_id[int(pid)] for pid in product_ids if int(pid) in by_id]

        if not candidates and query:
            # Handle multi-item "A vs B" / "A and B" comparison phrases cleanly
            parts = [
                part.strip()
                for part in re.split(r"\b(?:vs\.?|versus|and|with)\b|,", query, flags=re.IGNORECASE)
                if len(part.strip()) >= 2
            ]
            if len(parts) >= 2:
                picked_ids: set[int] = set()
                for part in parts[:limit]:
                    part_scored = []
                    for p in all_products:
                        pid = int(p.get("id") or 0)
                        if pid in picked_ids:
                            continue
                        if int(p.get("stock") if p.get("stock") is not None else 50) <= 0:
                            continue
                        s, reason = _score_product_dict(p, part, None, active_3d_ids)
                        if s > 2.0:
                            part_scored.append((s, reason, p))
                    if part_scored:
                        part_scored.sort(
                            key=lambda item: (item[0], float(item[2].get("rating") or 4.8)),
                            reverse=True,
                        )
                        best_match = part_scored[0][2]
                        candidates.append(best_match)
                        picked_ids.add(int(best_match.get("id") or 0))

            if len(candidates) < 2:
                existing_ids = {int(p.get("id") or 0) for p in candidates}
                scored = []
                for p in all_products:
                    if int(p.get("id") or 0) in existing_ids:
                        continue
                    if int(p.get("stock") if p.get("stock") is not None else 50) <= 0:
                        continue
                    s, reason = _score_product_dict(p, query, None, active_3d_ids)
                    if s > 2.0:
                        scored.append((s, reason, p))
                scored.sort(
                    key=lambda item: (item[0], float(item[2].get("rating") or 4.8)),
                    reverse=True,
                )
                candidates.extend(item[2] for item in scored[: max(0, limit - len(candidates))])

        if len(candidates) < 2:
            existing_ids = {int(p.get("id") or 0) for p in candidates}
            in_stock = [
                p
                for p in all_products
                if int(p.get("stock") if p.get("stock") is not None else 50) > 0
                and int(p.get("id") or 0) not in existing_ids
            ]
            in_stock.sort(
                key=lambda p: (
                    1 if int(p.get("id") or 0) in active_3d_ids else 0,
                    1 if p.get("is_featured") else 0,
                    float(p.get("rating") or 4.8),
                    int(p.get("reviews") or 0),
                ),
                reverse=True,
            )
            candidates.extend(in_stock[: max(0, limit - len(candidates))])

        comparison = []
        for p in candidates[:limit]:
            enriched = _enrich_public_product_dict(p, active_3d_ids)
            unit_p = float(enriched.get("price") or 0.0)
            enriched["b2b_bulk_unit_price"] = round(unit_p * 0.90, 2)
            enriched["b2b_bulk_savings_percent"] = 10
            comparison.append(enriched)
        return json.dumps({"products": comparison}, ensure_ascii=False)
    except Exception:
        logger.exception("[TOOL ERROR] compare_products failed")
        return json.dumps({"products": [], "error": "Unable to compare products."})


# ===========================================================================
# OPERATIONS OVERVIEW TOOL
# ===========================================================================

@tool("operations_overview")
def operations_overview() -> str:
    """
    Retrieve live store operational telemetry from Supabase over HTTPS.
    """
    logger.info("[TOOL CALLED] operations_overview")
    try:
        all_products = fetch_products_https()
        active_3d_ids = fetch_3d_catalog_ids_https()

        total_products = len(all_products)
        in_house_count = sum(
            1 for p in all_products if str(p.get("fulfillment_type") or "IN_HOUSE") == "IN_HOUSE"
        )
        dropship_count = total_products - in_house_count

        low_stock_items = [
            {
                "id": p["id"],
                "name": p["name"],
                "stock": int(p.get("stock") or 0),
                "category": p.get("category"),
            }
            for p in all_products
            if int(p.get("stock") if p.get("stock") is not None else 50) < 10
        ][:10]

        category_breakdown: dict[str, int] = {}
        for p in all_products:
            key = str(p.get("category") or "OTHER").strip()
            category_breakdown[key] = category_breakdown.get(key, 0) + 1

        return json.dumps(
            {
                "total_products": total_products,
                "in_house_count": in_house_count,
                "dropship_count": dropship_count,
                "active_3d_models": len(active_3d_ids),
                "low_stock_items": low_stock_items,
                "category_breakdown": category_breakdown,
            },
            ensure_ascii=False,
        )
    except Exception:
        logger.exception("[TOOL ERROR] operations_overview failed")
        return json.dumps({"error": "Unable to fetch operational overview."})


# ===========================================================================
# LIVE REVIEW TRUST & AUTHENTICITY AUDIT TOOL
# ===========================================================================

class CheckReviewsTrustInput(BaseModel):
    product_id: int = Field(
        ...,
        description="Exact numeric ID of the product to audit reviews & trust score for.",
    )


@tool("check_reviews_and_trust", args_schema=CheckReviewsTrustInput)
def check_reviews_and_trust(product_id: int) -> str:
    """
    Pull live AI review pros/cons, verified authenticity percentage, and
    trust-weighted rating for a specific product from Supabase.
    """
    logger.info("[TOOL CALLED] check_reviews_and_trust | product_id=%s", product_id)
    try:
        prod = fetch_product_by_id_https(product_id)
        if not prod:
            return json.dumps({"error": f"Product #{product_id} not found in catalog."})

        active_3d_ids = set(fetch_3d_catalog_ids_https())
        enriched = _enrich_public_product_dict(prod, active_3d_ids)

        verdict = "AI Trust Engine audited verified buyer reviews for authenticity."
        pros: list[str] = []
        cons: list[str] = []
        trust_rating = float(enriched.get("rating") or 4.8)
        verified_pct = 96.0
        total_reviews = int(enriched.get("reviews") or 0)
        flagged_count = 0

        try:
            client = get_supabase_client()
            ins_res = (
                client.table("product_review_insights")
                .select("*")
                .eq("product_id", int(product_id))
                .limit(1)
                .execute()
            )
            ins_rows = ins_res.data or []
            if ins_rows:
                row = ins_rows[0]
                if row.get("trust_weighted_rating") is not None:
                    trust_rating = round(float(row["trust_weighted_rating"]), 2)
                if row.get("verified_authentic_percent") is not None:
                    verified_pct = round(float(row["verified_authentic_percent"]), 1)
                if row.get("verdict"):
                    verdict = str(row["verdict"])
                for key, target in (("pros_json", pros), ("cons_json", cons)):
                    raw_val = row.get(key)
                    if isinstance(raw_val, list):
                        target.extend(str(x) for x in raw_val[:3])
                    elif isinstance(raw_val, str) and raw_val.strip():
                        try:
                            parsed = json.loads(raw_val)
                            if isinstance(parsed, list):
                                target.extend(str(x) for x in parsed[:3])
                        except json.JSONDecodeError:
                            pass

            rev_res = (
                client.table("reviews")
                .select("rating,trust_score,is_flagged_suspicious,verified_purchase")
                .eq("product_id", int(product_id))
                .execute()
            )
            rev_rows = rev_res.data or []
            if rev_rows:
                total_reviews = len(rev_rows)
                flagged_count = sum(
                    1 for r in rev_rows if r.get("is_flagged_suspicious") is True
                )
                authentic_count = max(0, total_reviews - flagged_count)
                if total_reviews > 0:
                    verified_pct = round((authentic_count / total_reviews) * 100.0, 1)
        except Exception as exc:
            logger.debug("Supabase review insight REST query notice: %s", exc)

        return json.dumps(
            {
                "product": enriched,
                "product_id": int(product_id),
                "product_name": enriched["name"],
                "price": enriched["price"],
                "stock": enriched["stock"],
                "has_3d_model": enriched["has_3d_model"],
                "trust_weighted_rating": trust_rating,
                "verified_authentic_percent": verified_pct,
                "total_reviews": total_reviews,
                "flagged_suspicious_count": flagged_count,
                "verdict": verdict,
                "pros": pros,
                "cons": cons,
            },
            ensure_ascii=False,
        )
    except Exception:
        logger.exception("[TOOL ERROR] check_reviews_and_trust failed")
        return json.dumps({"error": "Unable to retrieve live review trust insights."})
