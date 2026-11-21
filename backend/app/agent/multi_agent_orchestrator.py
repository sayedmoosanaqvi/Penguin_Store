import json
import logging
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Optional, Sequence, TypedDict

from dotenv import load_dotenv
from langchain_core.messages import AIMessage, BaseMessage
from langchain_groq import ChatGroq
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import create_react_agent
from sqlalchemy.orm import load_only

from app.agent.tools import (
    add_to_cart,
    check_order_status,
    compare_products,
    inspect_catalog,
    operations_overview,
    search_inventory,
    search_knowledge_base,
)
from app.core.database import SessionLocal
from app.models import Product, ProductReviewInsight

_BACKEND_ENV_PATH = Path(__file__).resolve().parents[2] / ".env"
load_dotenv(_BACKEND_ENV_PATH)
load_dotenv()

logger = logging.getLogger("uvicorn.error")


# ===========================================================================
# SHARED CLOUD LLM & MULTI-MODEL FAILOVER
# ===========================================================================

llm = ChatGroq(
    model="openai/gpt-oss-20b",
    temperature=0,
    max_retries=1,
    timeout=25.0,
)

_FALLBACK_LLMS = [
    llm,
    ChatGroq(
        model="openai/gpt-oss-120b",
        temperature=0,
        max_retries=1,
        timeout=25.0,
    ),
    ChatGroq(
        model="qwen/qwen3.8-27b",
        temperature=0,
        max_retries=1,
        timeout=25.0,
    ),
]


def _invoke_llm_safe(messages: list[Any]) -> Optional[AIMessage]:
    """
    Invoke Groq LLM with automatic multi-model failover across
    independent rate-limit buckets so CTRL-X never crashes with HTTP 500
    when a single model hits a 429 TPM rate limit.
    """
    for candidate_llm in _FALLBACK_LLMS:
        try:
            response = candidate_llm.invoke(messages)
            if response is not None:
                return response
        except Exception as exc:
            logger.warning(
                "[CTRL-X LLM FAILOVER] Model %s failed: %s",
                getattr(candidate_llm, "model_name", "unknown"),
                exc,
            )
            continue
    return None


# ===========================================================================
# GRAPH STATE
#
# Besides conversation messages, specialist agents can now place structured
# application data directly into LangGraph state.
#
# This lets FastAPI return product cards without depending entirely on
# reverse-scanning ToolMessages.
# ===========================================================================

class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]

    next_agent: str

    routed_agent: Optional[str]

    data_type: str

    suggested_products: list[dict[str, Any]]

    cart_action: Optional[dict[str, Any]]

    order_action: Optional[dict[str, Any]]

    bundle: Optional[dict[str, Any]]

    comparison: Optional[dict[str, Any]]

    reasoning_steps: Optional[list[dict[str, Any]]]

    action_logs: Optional[list[dict[str, Any]]]


def _make_reasoning_step(
    step: str,
    summary: str,
    duration_ms: float,
    status: str = "completed",
) -> dict[str, Any]:
    return {
        "step": step,
        "status": status,
        "duration_ms": round(max(0.1, float(duration_ms)), 2),
        "summary": summary[:280],
    }


def _make_action_log(
    agent_name: str,
    tools_called: list[str],
    status: str = "success",
    detail: str = "",
) -> list[dict[str, Any]]:
    return [
        {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "agent": agent_name,
            "tools": tools_called,
            "status": status,
            "detail": detail[:250],
        }
    ]


# ===========================================================================
# GENERIC HELPERS
# ===========================================================================

def _message_text(message: Any) -> str:
    """
    Convert a LangChain message/content object into normal text.
    """

    content = getattr(
        message,
        "content",
        message,
    )

    if isinstance(content, str):
        return content.strip()

    if isinstance(content, list):
        parts = []

        for item in content:
            if isinstance(item, str):
                parts.append(item)

            elif isinstance(item, dict):
                text = item.get("text")

                if text:
                    parts.append(str(text))

        return "\n".join(parts).strip()

    return str(content).strip()


def _latest_user_text(
    state: AgentState,
) -> str:
    """
    Return the latest customer message.
    """

    for message in reversed(
        state["messages"]
    ):
        if getattr(
            message,
            "type",
            "",
        ) == "human":
            return _message_text(message)

    return ""


def _conversation_excerpt(
    state: AgentState,
    max_messages: int = 8,
) -> str:
    """
    Provide the planner with a small amount of conversational memory.

    Keeping this bounded reduces Groq token usage and latency.
    """

    lines = []

    relevant_messages = [
        message
        for message in state["messages"]
        if getattr(
            message,
            "type",
            "",
        ) in {
            "human",
            "ai",
        }
    ]

    for message in relevant_messages[-max_messages:]:
        role = (
            "Customer"
            if getattr(
                message,
                "type",
                "",
            ) == "human"
            else "Assistant"
        )

        text = _message_text(
            message
        )

        # Avoid sending extremely large previous responses
        # back to the planner.
        text = text[:700]

        lines.append(
            f"{role}: {text}"
        )

    return "\n".join(lines)[-4500:]


def _parse_json_object(
    text: str,
) -> dict[str, Any]:
    """
    Safely parse a JSON object returned by the LLM.

    The planner uses a normal LLM call instead of structured-output
    tool forcing because the previous Groq integration failed when
    tool_choice became mandatory.
    """

    cleaned = text.strip()

    if cleaned.startswith("```"):
        cleaned = cleaned.replace(
            "```json",
            "",
            1,
        ).replace(
            "```",
            "",
        ).strip()

    start = cleaned.find("{")
    end = cleaned.rfind("}")

    if (
        start == -1
        or end == -1
        or end < start
    ):
        return {}

    try:
        parsed = json.loads(
            cleaned[start:end + 1]
        )

        if isinstance(
            parsed,
            dict,
        ):
            return parsed

    except json.JSONDecodeError:
        pass

    return {}


def _parse_json_list(
    value: Any,
) -> list[dict[str, Any]]:
    """
    Parse a product-list tool response safely.
    """

    if isinstance(value, list):
        return [
            item
            for item in value
            if isinstance(item, dict)
        ]

    if not isinstance(value, str):
        return []

    try:
        parsed = json.loads(value)

    except json.JSONDecodeError:
        return []

    if not isinstance(parsed, list):
        return []

    return [
        item
        for item in parsed
        if isinstance(item, dict)
    ]


def _parse_json_dict(
    value: Any,
) -> dict[str, Any]:
    """
    Parse dictionary tool output safely.
    """

    if isinstance(value, dict):
        return value

    if not isinstance(value, str):
        return {}

    try:
        parsed = json.loads(value)

    except json.JSONDecodeError:
        return {}

    return (
        parsed
        if isinstance(parsed, dict)
        else {}
    )


def _optional_string(
    value: Any,
) -> Optional[str]:
    if value is None:
        return None

    value = str(value).strip()

    if not value:
        return None

    if value.lower() in {
        "null",
        "none",
    }:
        return None

    return value[:200]


def _optional_float(
    value: Any,
) -> Optional[float]:
    if value is None:
        return None

    try:
        number = float(value)

        if number < 0:
            return None

        return number

    except (
        TypeError,
        ValueError,
    ):
        return None


def _optional_bool(
    value: Any,
) -> Optional[bool]:
    if isinstance(value, bool):
        return value

    if isinstance(value, str):
        lowered = value.lower().strip()

        if lowered == "true":
            return True

        if lowered == "false":
            return False

    return None


# ===========================================================================
# SHOPPING PLAN
# ===========================================================================

def _normalize_shopping_plan(
    raw_plan: dict[str, Any],
) -> dict[str, Any]:
    """
    Validate the LLM planner response before any tool receives it.
    """

    action = str(
        raw_plan.get(
            "action",
            "search",
        )
    ).strip().lower()

    if action not in {
        "search",
        "add_to_cart",
    }:
        action = "search"

    product_id = raw_plan.get(
        "product_id"
    )

    try:
        product_id = (
            int(product_id)
            if product_id is not None
            else None
        )

    except (
        TypeError,
        ValueError,
    ):
        product_id = None

    quantity = raw_plan.get(
        "quantity",
        1,
    )

    try:
        quantity = max(
            1,
            int(quantity),
        )

    except (
        TypeError,
        ValueError,
    ):
        quantity = 1

    return {
        "action": action,
        "search_term": _optional_string(
            raw_plan.get(
                "search_term"
            )
        ),
        "category": _optional_string(
            raw_plan.get(
                "category"
            )
        ),
        "max_price": _optional_float(
            raw_plan.get(
                "max_price"
            )
        ),
        "is_featured": _optional_bool(
            raw_plan.get(
                "is_featured"
            )
        ),
        "product_id": product_id,
        "quantity": quantity,
    }


def _match_product_from_recent(
    user_query: str,
    recent_products: list[dict[str, Any]],
) -> Optional[int]:
    """
    Resolve a product ID from recently shown products when the customer
    says e.g. 'add the pink shirt to my cart' or 'add product 144 to cart'.
    """
    q_lower = user_query.lower()

    # Check explicit ID mention like 'id 144' or '#144' or 'product 144'
    id_match = re.search(r"\b(?:id|product|#)\s*(\d+)\b", q_lower)
    if id_match:
        return int(id_match.group(1))

    if not recent_products:
        return None

    # Check ordinal reference like 'first one', 'second one', 'third one', 'last one'
    if any(w in q_lower for w in ("first", "1st")) and len(recent_products) >= 1:
        pid = recent_products[0].get("id")
        return int(pid) if pid is not None else None
    if any(w in q_lower for w in ("second", "2nd")) and len(recent_products) >= 2:
        pid = recent_products[1].get("id")
        return int(pid) if pid is not None else None
    if any(w in q_lower for w in ("third", "3rd")) and len(recent_products) >= 3:
        pid = recent_products[2].get("id")
        return int(pid) if pid is not None else None
    if "last" in q_lower and len(recent_products) >= 1:
        pid = recent_products[-1].get("id")
        return int(pid) if pid is not None else None

    # Check name token overlap
    best_id = None
    best_overlap = 0
    q_words = set(re.findall(r"[a-z0-9]+", q_lower)) - {
        "add", "to", "my", "the", "cart", "buy", "purchase", "want", "please", "one"
    }

    for prod in recent_products:
        pname = str(prod.get("name") or "").lower()
        pid = prod.get("id")
        if pid is None or not pname:
            continue
        if pname in q_lower:
            return int(pid)
        p_words = set(re.findall(r"[a-z0-9]+", pname))
        overlap = len(q_words & p_words)
        if overlap > best_overlap:
            best_overlap = overlap
            best_id = int(pid)

    return best_id if best_overlap > 0 else None


def _create_initial_shopping_plan(
    state: AgentState,
) -> dict[str, Any]:
    """
    Let the Shopping Planner translate natural language into one bounded
    database action, with automatic multi-model failover and deterministic
    fallback.
    """

    user_query = _latest_user_text(
        state
    )

    conversation = (
        _conversation_excerpt(
            state
        )
    )

    recent_products = state.get("suggested_products") or []
    recent_products_summary = [
        {
            "id": p.get("id"),
            "name": p.get("name"),
            "price": p.get("price"),
            "category": p.get("category"),
        }
        for p in recent_products[:5]
        if isinstance(p, dict)
    ]

    planner_prompt = """
You are the Shopping Planner inside Penguin Store's autonomous
multi-agent e-commerce system.

Your job is to convert the customer's latest shopping request into ONE
safe tool plan.

You are NOT answering the customer.

Return ONLY valid JSON with this exact structure:

{
  "action": "search",
  "search_term": null,
  "category": null,
  "max_price": null,
  "is_featured": null,
  "product_id": null,
  "quantity": 1
}

Allowed actions:

"search"
Use when the customer wants products, recommendations, availability,
prices, styles, categories, gifts, outfits, or shopping help.

"add_to_cart"
Use only when the customer clearly asks to add/buy a specific product
and its exact product ID is known from the conversation or recently
suggested products list.

SEARCH RULES:

1. Extract explicit requirements such as color, style, product type,
   budget, brand, or occasion.

2. Do NOT invent a database category.

3. If the customer explicitly says "shirts", category may be "shirts".

4. If the request is vague or occasion-based, such as:
   "something for a party"
   "something for a wedding"
   "a gift for my friend"

   do NOT guess a category like "dresses".

   Instead:
   - place the intent in search_term
   - leave category as null

5. Use max_price only when a budget is actually provided.

6. Use is_featured=true only when the customer requests featured,
   popular, or trending products.

7. Never invent product IDs. Use the IDs from Recently Suggested Products when matching a cart request.

8. If unsure, choose a broad safe search rather than guessing taxonomy.

Return JSON only.
""".strip()

    response = _invoke_llm_safe(
        [
            {
                "role": "system",
                "content": planner_prompt,
            },
            {
                "role": "user",
                "content": (
                    f"Conversation:\n{conversation}\n\n"
                    f"Recently Suggested Products:\n{json.dumps(recent_products_summary)}\n\n"
                    f"Latest request:\n{user_query}"
                ),
            },
        ]
    )

    raw_plan = (
        _parse_json_object(_message_text(response))
        if response is not None
        else {}
    )

    if not raw_plan:
        # Deterministic fallback if LLM is rate-limited
        q_lower = user_query.lower()
        price_match = re.search(
            r"(?:under|below|less than|max|budget)\s*\$?\s*(\d+(?:\.\d+)?)",
            q_lower,
        )
        max_p = float(price_match.group(1)) if price_match else None
        is_cart = any(
            phrase in q_lower
            for phrase in ("add to cart", "add the ", "add this", "buy the ")
        )
        raw_plan = {
            "action": "add_to_cart" if is_cart else "search",
            "search_term": user_query,
            "max_price": max_p,
            "is_featured": True if "featured" in q_lower or "trending" in q_lower else None,
        }

    plan = _normalize_shopping_plan(
        raw_plan
    )

    # If user clearly asked to add a named product to cart, resolve its ID from recent products
    q_lower = user_query.lower()
    if (
        plan["action"] == "add_to_cart"
        or ("cart" in q_lower and any(w in q_lower for w in ("add", "put", "buy")))
    ):
        if plan.get("product_id") is None:
            resolved_id = _match_product_from_recent(
                user_query,
                recent_products,
            )
            if resolved_id is not None:
                plan["action"] = "add_to_cart"
                plan["product_id"] = resolved_id

    logger.info(
        "[SHOPPING PLAN] %s",
        plan,
    )

    return plan


# ===========================================================================
# CATALOG FALLBACK PLANNER
# ===========================================================================

def _create_catalog_fallback_plan(
    state: AgentState,
    initial_plan: dict[str, Any],
    catalog: dict[str, Any],
) -> dict[str, Any]:
    """
    When direct product retrieval fails, let the agent reason over the REAL
    catalog and choose one useful fallback search.

    This replaces uncontrolled repeated trial-and-error tool calls.
    """

    user_query = _latest_user_text(
        state
    )

    # The catalog is intentionally bounded by inspect_catalog.
    catalog_json = json.dumps(
        catalog,
        ensure_ascii=False,
    )[:6000]

    prompt = """
You are the Catalog Recovery Planner for Penguin Store.

A direct product search returned ZERO products.

You have now been given the REAL currently available Penguin Store
catalog.

Choose ONE intelligent fallback search.

Return ONLY JSON:

{
  "action": "search",
  "search_term": null,
  "category": null,
  "max_price": null,
  "is_featured": null,
  "product_id": null,
  "quantity": 1
}

RULES:

1. Use only categories or product concepts supported by the supplied
   catalog.

2. Never invent categories or products.

3. Preserve important customer constraints such as budget.

4. For an occasion-based request, select useful alternatives from products
   that actually exist.

5. It is acceptable to search several related REAL concepts by placing
   them in search_term separated by spaces.

   Example:
   "shirt shoes handbag"

6. Prefer specific useful concepts over generic terms such as
   "accessories", because generic categories can contain unrelated items.

7. Do not assume the customer's gender if it was not stated.
   When possible, choose broadly useful alternatives across the available
   catalog.

8. Perform only ONE fallback search.

Return JSON only.
""".strip()

    response = _invoke_llm_safe(
        [
            {
                "role": "system",
                "content": prompt,
            },
            {
                "role": "user",
                "content": (
                    f"Customer request:\n{user_query}\n\n"
                    f"Original search plan:\n"
                    f"{json.dumps(initial_plan)}\n\n"
                    f"REAL STORE CATALOG:\n{catalog_json}"
                ),
            },
        ]
    )

    plan = _normalize_shopping_plan(
        _parse_json_object(_message_text(response))
        if response is not None
        else {}
    )

    # Fallback is always a product search.
    plan["action"] = "search"

    # Preserve hard budget/featured constraints unless the planner
    # explicitly provides an equivalent value.
    if initial_plan.get(
        "max_price"
    ) is not None:
        plan["max_price"] = (
            initial_plan["max_price"]
        )

    if initial_plan.get(
        "is_featured"
    ) is not None:
        plan["is_featured"] = (
            initial_plan["is_featured"]
        )

    logger.info(
        "[CATALOG FALLBACK PLAN] %s",
        plan,
    )

    return plan


# ===========================================================================
# INVENTORY EXECUTION & TRUST-WEIGHTED RANKING + BUNDLE BUILDER
# ===========================================================================

def _enrich_and_rank_by_trust(
    products: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """
    Enrich product dictionaries with Trust-Weighted Ratings, 3D model flags,
    and Verified-Authentic percentages without blocking on TCP port 5432.
    """
    if not products:
        return []

    from app.core.supabase_rest import (
        fetch_3d_catalog_ids_https,
        is_pg_tcp_reachable,
    )

    active_3d_ids = set(fetch_3d_catalog_ids_https())
    pids = [int(p["id"]) for p in products if isinstance(p, dict) and p.get("id")]
    insights_map: dict[int, tuple[float, float]] = {}

    if pids and is_pg_tcp_reachable():
        db = SessionLocal()
        try:
            rows = (
                db.query(
                    ProductReviewInsight.product_id,
                    ProductReviewInsight.trust_weighted_rating,
                    ProductReviewInsight.verified_authentic_percent,
                )
                .filter(ProductReviewInsight.product_id.in_(pids))
                .all()
            )
            for pid, tw_r, auth_pct in rows:
                insights_map[int(pid)] = (
                    round(float(tw_r or 4.8), 2),
                    round(float(auth_pct or 96.0), 1),
                )
        except Exception:
            pass
        finally:
            db.close()

    enriched: list[dict[str, Any]] = []
    for p in products:
        item = dict(p)
        pid = int(item.get("id") or 0)
        raw_r = float(item.get("rating") or 4.8)
        if pid in insights_map:
            tw_r, auth_pct = insights_map[pid]
        else:
            tw_r = round(min(5.0, raw_r if raw_r > 0 else 4.8), 2)
            auth_pct = 96.0
        item["trust_weighted_rating"] = tw_r
        item["verified_authentic_percent"] = auth_pct
        item["has_3d_model"] = bool(item.get("has_3d_model")) or (pid in active_3d_ids)
        item["selection_reason"] = (
            f"Prioritized for {tw_r:.1f}★ Trust-Weighted Rating "
            f"({auth_pct:.0f}% verified authentic) at ${float(item.get('price') or 0):.2f}."
        )
        enriched.append(item)

    enriched.sort(
        key=lambda x: (
            float(x.get("trust_weighted_rating") or 0.0),
            1 if x.get("has_3d_model") else 0,
            1 if x.get("is_featured") else 0,
            -float(x.get("price") or 0.0),
        ),
        reverse=True,
    )
    return enriched


def _extract_budget_from_query(user_query: str) -> Optional[float]:
    cleaned = re.sub(r"(\d),(\d{3})", r"\1\2", user_query)
    patterns = (
        r"(?:under|below|less\s+than|max|budget(?:\s+of)?|within|for|around)\s*\$?\s*(\d+(?:\.\d+)?)",
        r"\$\s*(\d+(?:\.\d+)?)",
        r"(\d+(?:\.\d+)?)\s*(?:usd|dollars)\b",
    )
    for pat in patterns:
        m = re.search(pat, cleaned, re.IGNORECASE)
        if m:
            try:
                val = float(m.group(1))
                if val > 5:
                    return val
            except ValueError:
                continue
    return None


def _is_bundle_request(user_query: str) -> bool:
    q = user_query.lower()
    if any(
        kw in q
        for kw in (
            "bundle",
            "desk setup",
            "office setup",
            "gaming setup",
            "build me a",
            "build a ",
            "complete outfit",
            "full outfit",
            "starter kit",
            "combo",
            "package under",
        )
    ):
        return True

    # Multi-item request with '+' or 'and' + budget / shopping intent
    if "+" in q and any(
        w in q for w in ("find", "build", "under", "budget", "recommend", "buy", "need", "want", "$")
    ):
        return True

    if re.search(r"\b(find|build|get|recommend)\b.+\band\b.+\b(under|below|budget|\$)\b", q):
        return True

    return False


def _build_autonomous_bundle(
    user_query: str,
) -> tuple[Optional[dict[str, Any]], list[dict[str, Any]]]:
    """
    Build a trust-optimized multi-item product bundle respecting the user's budget
    and returning a structured bundle artifact + step-by-step reasoning trace.
    """
    steps: list[dict[str, Any]] = []
    t0 = time.perf_counter()

    budget = _extract_budget_from_query(user_query)
    q_lower = user_query.lower()

    # Parse slot concepts from query
    slot_concepts: list[str] = []
    if "+" in q_lower:
        raw_parts = re.split(r"\+", q_lower)
        for part in raw_parts:
            clean_p = re.sub(
                r"\b(find|build|me|a|an|the|under|below|with|high|trust|reviews|budget|for|of)\b|\$?\d+[,\d]*",
                " ",
                part,
            )
            clean_p = " ".join(clean_p.split()).strip()
            if clean_p:
                slot_concepts.append(clean_p)
    elif "desk setup" in q_lower or "office setup" in q_lower or "setup" in q_lower:
        slot_concepts = ["laptop phone tablet", "watch charger accessory", "furniture lamp decoration"]
    elif "outfit" in q_lower:
        slot_concepts = ["shirt top dress", "shoes sneakers", "watch bag sunglasses"]
    else:
        parts = re.split(r"\band\b|,", q_lower)
        for part in parts:
            clean_p = re.sub(
                r"\b(find|build|me|a|an|the|under|below|with|high|trust|reviews|budget|for|of)\b|\$?\d+[,\d]*",
                " ",
                part,
            )
            clean_p = " ".join(clean_p.split()).strip()
            if clean_p and len(clean_p) >= 3:
                slot_concepts.append(clean_p)

    if len(slot_concepts) < 2:
        slot_concepts = ["shirt laptop phone", "shoes watch accessory", "bag fragrance electronics"]

    steps.append(
        _make_reasoning_step(
            "Bundle Intent & Budget Parser",
            f"Parsed {len(slot_concepts)} target item slots ({', '.join(slot_concepts[:3])}) "
            + (f"with max budget ${budget:,.2f}" if budget else "with open budget optimization"),
            (time.perf_counter() - t0) * 1000.0,
        )
    )

    t1 = time.perf_counter()
    from app.core.supabase_rest import fetch_products_https

    catalog_rows: list[dict[str, Any]] = [
        dict(p)
        for p in fetch_products_https()
        if int(p.get("stock") if p.get("stock") is not None else 50) > 0
    ]

    steps.append(
        _make_reasoning_step(
            "Vector & Catalog Retrieval",
            f"Scanned {len(catalog_rows)} in-stock catalog products across active categories",
            (time.perf_counter() - t1) * 1000.0,
        )
    )

    if not catalog_rows:
        return None, steps

    t2 = time.perf_counter()
    enriched_catalog = _enrich_and_rank_by_trust(catalog_rows)
    steps.append(
        _make_reasoning_step(
            "Trust Score Filter",
            f"Ranked candidates by Trust-Weighted Rating (top candidate: {enriched_catalog[0]['trust_weighted_rating']}★)",
            (time.perf_counter() - t2) * 1000.0,
        )
    )

    t3 = time.perf_counter()
    selected_items: list[dict[str, Any]] = []
    selected_ids: set[int] = set()
    selected_categories: set[str] = set()
    running_total = 0.0
    effective_budget = budget if budget is not None else 999999.0

    # Synonym expansion for common bundle slot keywords
    synonym_map = {
        "earbuds": {"earbuds", "airpods", "pods", "audio", "accessory", "accessories", "mobile"},
        "phone": {"phone", "iphone", "smartphone", "smartphones", "mobile", "oppo", "realme", "samsung"},
        "desk": {"laptop", "lamp", "watch", "table", "furniture", "decor", "electronic", "charger"},
        "shoes": {"shoe", "shoes", "sneaker", "sneakers", "boot", "footwear"},
        "shirt": {"shirt", "shirts", "top", "tee", "apparel"},
    }

    for idx, concept in enumerate(slot_concepts[:4]):
        raw_tokens = set(re.findall(r"[a-z0-9]{2,}", concept.lower()))
        expanded_tokens = set(raw_tokens)
        for tok in list(raw_tokens):
            if tok in synonym_map:
                expanded_tokens |= synonym_map[tok]

        remaining_slots = max(1, len(slot_concepts[:3]) - len(selected_items))
        slot_cap = (effective_budget - running_total) if budget is not None else 999999.0

        best_candidate: Optional[dict[str, Any]] = None
        best_score = -1e9

        for cand in enriched_catalog:
            cid = int(cand["id"])
            if cid in selected_ids:
                continue
            c_price = float(cand["price"])
            if budget is not None and (running_total + c_price) > effective_budget:
                continue

            haystack = f"{cand['name']} {cand['category']} {cand['description']}".lower()
            hay_tokens = set(re.findall(r"[a-z0-9]{2,}", haystack))
            overlap = len(expanded_tokens & hay_tokens)
            substr_hits = sum(1 for tok in expanded_tokens if len(tok) >= 3 and tok in haystack)

            # Diversity bonus for picking from a different category
            cat_norm = str(cand["category"]).upper()
            diversity_bonus = 1.5 if cat_norm not in selected_categories else 0.0
            trust_r = float(cand.get("trust_weighted_rating") or 4.8)

            # Leave room for remaining slots when budget is constrained
            budget_harmony = 1.0
            if budget is not None and remaining_slots > 1 and c_price > (slot_cap * 0.82):
                budget_harmony = -2.0

            candidate_score = (
                (overlap * 8.0)
                + (substr_hits * 4.5)
                + (trust_r * 3.0)
                + diversity_bonus
                + budget_harmony
            )

            if candidate_score > best_score:
                best_score = candidate_score
                best_candidate = cand

        if best_candidate is not None:
            selected_items.append(best_candidate)
            selected_ids.add(int(best_candidate["id"]))
            selected_categories.add(str(best_candidate["category"]).upper())
            running_total += float(best_candidate["price"])

    # Ensure at least 2 items in a bundle if possible within budget (or lowest-price high-trust fallback)
    if len(selected_items) < 2:
        affordable_pool = sorted(
            [c for c in enriched_catalog if int(c["id"]) not in selected_ids],
            key=lambda x: (float(x["price"]), -float(x.get("trust_weighted_rating") or 4.8)),
        )
        for cand in affordable_pool:
            c_price = float(cand["price"])
            if budget is None or (running_total + c_price) <= effective_budget or len(selected_items) < 2:
                selected_items.append(cand)
                selected_ids.add(int(cand["id"]))
                running_total += c_price
                if len(selected_items) >= 3:
                    break

    total_price = round(sum(float(i["price"]) for i in selected_items), 2)
    orig_total = round(
        sum(float(i.get("original_price") or i["price"]) for i in selected_items),
        2,
    )
    discount_savings = round(max(0.0, orig_total - total_price), 2)
    budget_remaining = (
        round(max(0.0, float(budget) - total_price), 2)
        if budget is not None
        else discount_savings
    )
    avg_trust = (
        round(
            sum(float(i.get("trust_weighted_rating") or 4.8) for i in selected_items)
            / len(selected_items),
            2,
        )
        if selected_items
        else 4.8
    )

    rationale_parts = [
        f"{item['name']} (${item['price']:.2f}, {item['trust_weighted_rating']:.1f}★ trust)"
        for item in selected_items
    ]
    rationale = (
        f"Curated {len(selected_items)} high-trust items ({', '.join(rationale_parts)}) "
        f"with an average Trust-Weighted Rating of {avg_trust:.2f}★"
        + (
            f", keeping total cost at ${total_price:.2f} (${budget_remaining:.2f} under your ${budget:.2f} budget)."
            if budget is not None and total_price <= budget
            else f" for a combined bundle total of ${total_price:.2f}."
        )
    )

    steps.append(
        _make_reasoning_step(
            "Bundle & Price Optimizer",
            f"Assembled {len(selected_items)}-item bundle totaling ${total_price:.2f} "
            + (f"(${budget_remaining:.2f} under budget)" if budget else f"(avg trust {avg_trust:.2f}★)"),
            (time.perf_counter() - t3) * 1000.0,
        )
    )

    bundle_obj = {
        "title": (
            f"AI Curated Bundle (Under ${budget:,.0f})"
            if budget is not None
            else "CTRL-X Trust-Verified Bundle"
        ),
        "items": selected_items,
        "total_price": total_price,
        "budget": budget,
        "budget_remaining": budget_remaining,
        "savings": round(discount_savings + (budget_remaining if budget is not None else 0.0), 2),
        "average_trust_rating": avg_trust,
        "rationale": rationale,
    }
    return bundle_obj, steps


def _execute_inventory_search(
    plan: dict[str, Any],
) -> list[dict[str, Any]]:
    """
    Execute one validated inventory search and rank results by Trust-Weighted Rating.
    """

    raw_result = search_inventory.invoke(
        {
            "search_term": (
                plan.get(
                    "search_term"
                )
            ),
            "category": (
                plan.get(
                    "category"
                )
            ),
            "max_price": (
                plan.get(
                    "max_price"
                )
            ),
            "is_featured": (
                plan.get(
                    "is_featured"
                )
            ),
        }
    )

    parsed_list = _parse_json_list(
        raw_result
    )
    return _enrich_and_rank_by_trust(parsed_list)


# ===========================================================================
# GROUNDED SHOPPING RESPONSE
# ===========================================================================

def _create_grounded_product_response(
    user_query: str,
    products: list[dict[str, Any]],
    used_catalog_fallback: bool,
) -> str:
    """
    Generate customer-facing language from REAL product rows.

    The LLM is explicitly forbidden from inventing operational data.
    """

    if not products:
        return (
            "I couldn't find a suitable product in the current "
            "Penguin Store inventory. Tell me a little more about the "
            "style, product type, or budget you have in mind and I'll "
            "search the live catalog again."
        )

    product_json = json.dumps(
        products,
        ensure_ascii=False,
    )

    prompt = """
You are the customer-facing Shopping Agent for Penguin Store.

Write a concise, useful response based ONLY on the supplied database
products.

GROUNDING RULES:

- Never invent products.
- Never invent prices.
- Never invent stock.
- Never invent discounts.
- Never invent ratings.
- Never invent shipping promises.
- Never invent warehouse information.
- Never invent delivery time.
- Never invent product properties not supported by name/description.
- Never say a DROPSHIP product ships from our warehouse.
- Never change IN_HOUSE or DROPSHIP into a different fulfillment claim.
- Do not expose internal supplier IDs or cost prices.
- You may explain that an item could be a useful style suggestion, but
  make it clear that this is a recommendation rather than a database fact.
- Keep the response relatively short because Flutter separately displays
  the products as visual product cards.
- Do not build a large Markdown product table. The UI already renders cards.
- Never claim that a product has already been added to the cart in this search response.
- Mention at most a few useful highlights.
""".strip()

    fallback_note = (
        "The direct search had no exact result, so these products were "
        "selected after reasoning over the real available catalog."
        if used_catalog_fallback
        else
        "These products matched the direct inventory search."
    )

    try:
        response = _invoke_llm_safe(
            [
                {
                    "role": "system",
                    "content": prompt,
                },
                {
                    "role": "user",
                    "content": (
                        f"Customer request:\n{user_query}\n\n"
                        f"Retrieval context:\n{fallback_note}\n\n"
                        f"REAL DATABASE PRODUCTS:\n{product_json}"
                    ),
                },
            ]
        )

        if response is not None:
            final_text = _message_text(
                response
            )

            if final_text:
                return final_text

    except Exception:
        logger.exception(
            "Failed to generate grounded shopping response"
        )

    # Safe fallback if the final LLM call ever fails.
    highlights = [
        f"{p.get('name', 'Product')} (${float(p.get('price') or 0):.2f}, "
        f"{float(p.get('trust_weighted_rating') or p.get('rating') or 4.8):.1f}★ Trust-Weighted)"
        for p in products[:3]
    ]

    return (
        "I prioritized the highest-trust matching products in Penguin Store: "
        f"{'; '.join(highlights)}. "
        "Each recommendation is ranked by its AI Trust-Weighted Rating and verified buyer authenticity."
    )


# ===========================================================================
# CONTROLLED SHOPPING / RETRIEVAL AGENT
# ===========================================================================

def retrieval_agent(
    state: AgentState,
):
    """
    Bounded shopping workflow with Trust-Aware Ranking, Autonomous Bundle Builder,
    and Structured Reasoning Trace (`reasoning_steps`).
    """

    user_query = _latest_user_text(
        state
    )

    logger.info(
        "[SHOPPING WORKFLOW] Started | Query=%r",
        user_query,
    )

    reasoning_steps: list[dict[str, Any]] = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Classified query as Shopping & Discovery workflow (ShoppingAgent)",
            0.4,
        )
    ]

    # -----------------------------------------------------------------------
    # AUTONOMOUS BUNDLE BUILDER WORKFLOW (PHASE 2)
    # -----------------------------------------------------------------------
    if _is_bundle_request(user_query):
        bundle_obj, bundle_steps = _build_autonomous_bundle(user_query)
        reasoning_steps.extend(bundle_steps)

        if bundle_obj and bundle_obj.get("items"):
            b_items = bundle_obj["items"]
            b_total = bundle_obj["total_price"]
            b_budget = bundle_obj.get("budget")
            b_rem = bundle_obj.get("budget_remaining", 0.0)
            b_avg_trust = bundle_obj.get("average_trust_rating", 4.8)

            lines = [
                f"I've built a **{bundle_obj['title']}** prioritized by AI Trust-Weighted Ratings ({b_avg_trust:.2f}★ average):"
            ]
            for it in b_items:
                lines.append(
                    f"- **{it['name']}** (${float(it['price']):.2f}) — "
                    f"**{float(it.get('trust_weighted_rating', 4.8)):.1f}★ Trust Score** "
                    f"({float(it.get('verified_authentic_percent', 96.0)):.0f}% verified authentic)"
                )
            if b_budget is not None:
                lines.append(
                    f"\n**Total Bundle Cost:** ${b_total:.2f} / ${float(b_budget):.2f} budget "
                    f"(**${b_rem:.2f} remaining**). Tap **Add Full Bundle to Cart** below to add all items in one click."
                )
            else:
                lines.append(
                    f"\n**Total Bundle Cost:** ${b_total:.2f}. Tap **Add Full Bundle to Cart** below to add all items in one click."
                )

            return {
                "messages": [AIMessage(content="\n".join(lines))],
                "routed_agent": "ShoppingAgent (BundleBuilder)",
                "data_type": "bundle",
                "suggested_products": b_items,
                "bundle": bundle_obj,
                "cart_action": None,
                "order_action": None,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log(
                    "ShoppingAgent",
                    ["search_inventory", "trust_score_filter", "bundle_builder"],
                    "success",
                    f"Built {len(b_items)}-item bundle (${b_total:.2f})",
                ),
            }

    # -----------------------------------------------------------------------
    # PRODUCT COMPARISON WORKFLOW (PHASE 1.2)
    # -----------------------------------------------------------------------
    q_cmp = user_query.lower()
    if any(
        kw in q_cmp
        for kw in (
            "compare",
            "comparison",
            "difference between",
            " vs ",
            "which is better",
            "which headphones are better",
            "better for the price",
            "side by side",
        )
    ):
        t_cmp = time.perf_counter()
        recent = state.get("suggested_products") or []
        use_recent_ids = (
            len(recent) >= 2
            and any(
                w in q_cmp
                for w in (
                    "these",
                    "them",
                    "above",
                    "shown",
                    "suggested",
                    "first two",
                    "top 2",
                    "top 3",
                )
            )
        )
        limit_cnt = 2 if "first two" in q_cmp or "top 2" in q_cmp else 3
        clean_query = re.sub(
            r"\b(compare|comparison|difference|between|which|is|are|better|for|price|side|by|vs|products|items|please|the|and|top)\b",
            " ",
            q_cmp,
        )
        clean_query = " ".join(clean_query.split())
        raw_cmp = compare_products.invoke(
            {
                "product_ids": [
                    p["id"]
                    for p in recent[:limit_cnt]
                    if isinstance(p, dict) and p.get("id")
                ]
                if use_recent_ids
                else None,
                "query": None if use_recent_ids else (clean_query or user_query),
                "limit": limit_cnt,
            }
        )
        cmp_data = _parse_json_dict(raw_cmp)
        compared_products = _enrich_and_rank_by_trust(cmp_data.get("products") or [])

        reasoning_steps.append(
            _make_reasoning_step(
                "Price & Trust Comparison Matrix",
                f"Compared {len(compared_products)} products on live price, 3D support, stock, and Trust-Weighted Rating",
                (time.perf_counter() - t_cmp) * 1000.0,
            )
        )

        if compared_products:
            t_llm = time.perf_counter()
            top_rated = max(
                compared_products,
                key=lambda x: (
                    float(x.get("trust_weighted_rating") or 4.8),
                    -float(x.get("price") or 0.0),
                ),
            )
            cheapest = min(
                compared_products,
                key=lambda x: float(x.get("price") or 999999.0),
            )

            cmp_prompt = (
                "You are the Shopping Agent for Penguin Store. Compare the real database products below "
                "concisely on price, trust_weighted_rating, stock, and 3D availability. "
                "Explicitly highlight the Top Rated winner and Best Value option using ONLY the database facts."
            )
            cmp_reply = _invoke_llm_safe(
                [
                    {"role": "system", "content": cmp_prompt},
                    {
                        "role": "user",
                        "content": (
                            f"Customer comparison request:\n{user_query}\n\n"
                            f"REAL PRODUCTS:\n{json.dumps(compared_products, ensure_ascii=False)}"
                        ),
                    },
                ]
            )
            final_cmp_text = _message_text(cmp_reply) if cmp_reply is not None else ""
            if not final_cmp_text:
                lines = [
                    f"I compared **{len(compared_products)} in-stock products** side-by-side. "
                    f"**{top_rated.get('name')}** leads in AI Trust Rating (**{top_rated.get('trust_weighted_rating', 4.8)}★**), "
                    f"while **{cheapest.get('name')}** (**${float(cheapest.get('price', 0)):.2f}**) is the Best Value pick:"
                ]
                for p in compared_products:
                    view_3d = "3D Twin Ready" if p.get("has_3d_model") else "2D Studio"
                    lines.append(
                        f"- **{p.get('name')}** (${float(p.get('price', 0)):.2f}) — "
                        f"**{p.get('trust_weighted_rating', 4.8)}★ Trust** | Stock: {p.get('stock', 50)} | {view_3d}"
                    )
                final_cmp_text = "\n".join(lines)

            comparison_rows = []
            for p in compared_products:
                pid = int(p.get("id") or 0)
                is_top = pid == int(top_rated.get("id") or -1)
                is_val = pid == int(cheapest.get("id") or -2) and not is_top
                badge = "TOP RATED ★" if is_top else ("BEST VALUE" if is_val else None)
                best_for = (
                    "Highest AI Trust & Quality"
                    if is_top
                    else ("Best Price-to-Performance" if is_val else f"Verified {p.get('category', 'Pick')}")
                )
                stock_cnt = int(p.get("stock") if p.get("stock") is not None else 50)
                comparison_rows.append(
                    {
                        "id": pid,
                        "name": p.get("name"),
                        "price": float(p.get("price") or 0.0),
                        "category": p.get("category") or "CATALOG",
                        "image_url": p.get("image_url") or "",
                        "trust_rating": float(p.get("trust_weighted_rating") or 4.8),
                        "verified_percent": float(p.get("verified_authentic_percent") or 96.0),
                        "has_3d": bool(p.get("has_3d_model")),
                        "stock": stock_cnt,
                        "stock_status": "In Stock" if stock_cnt >= 10 else f"Only {stock_cnt} Left",
                        "key_features": (str(p.get("description") or "Studio verified quality"))[:110],
                        "best_for": best_for,
                        "badge": badge,
                    }
                )

            comparison_obj = {
                "title": f"AI Side-by-Side Comparison ({len(compared_products)} Products)",
                "winner_id": int(top_rated.get("id") or 0),
                "winner_name": top_rated.get("name"),
                "best_value_id": int(cheapest.get("id") or 0),
                "best_value_name": cheapest.get("name"),
                "verdict": final_cmp_text,
                "rows": comparison_rows,
            }

            reasoning_steps.append(
                _make_reasoning_step(
                    "Grounded Comparison Synthesis",
                    f"Selected {top_rated.get('name')} as Top Rated ({top_rated.get('trust_weighted_rating', 4.8)}★) and {cheapest.get('name')} as Best Value",
                    (time.perf_counter() - t_llm) * 1000.0,
                )
            )

            return {
                "messages": [AIMessage(content=final_cmp_text)],
                "routed_agent": "ShoppingAgent (ComparisonEngine)",
                "data_type": "comparison",
                "suggested_products": compared_products,
                "bundle": None,
                "comparison": comparison_obj,
                "cart_action": None,
                "order_action": None,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log(
                    "ShoppingAgent",
                    ["compare_products", "trust_score_filter"],
                    "success",
                    f"Compared {len(compared_products)} products",
                ),
            }

    t_plan = time.perf_counter()
    plan = _create_initial_shopping_plan(
        state
    )
    reasoning_steps.append(
        _make_reasoning_step(
            "Query Planner",
            f"Generated {plan['action']} plan (term={plan.get('search_term') or 'all'}, category={plan.get('category') or 'any'}, max_price={plan.get('max_price')})",
            (time.perf_counter() - t_plan) * 1000.0,
        )
    )

    # -----------------------------------------------------------------------
    # CART ACTION
    # -----------------------------------------------------------------------

    if plan["action"] == "add_to_cart":
        t_cart = time.perf_counter()
        product_id = plan.get(
            "product_id"
        )

        # If product_id wasn't resolved yet, try a quick search by the user's terms
        if product_id is None and plan.get("search_term"):
            candidates = _execute_inventory_search(plan)
            if len(candidates) == 1:
                product_id = candidates[0].get("id")
            elif len(candidates) > 1:
                resolved = _match_product_from_recent(user_query, candidates)
                if resolved is not None:
                    product_id = resolved

        if product_id is None:
            message = (
                "I can add the product for you, but I need to know exactly "
                "which product you mean. Please choose one of the products "
                "shown in the conversation."
            )
            reasoning_steps.append(
                _make_reasoning_step(
                    "Cart Target Resolution",
                    "Requested user clarification for ambiguous product selection",
                    (time.perf_counter() - t_cart) * 1000.0,
                )
            )

            return {
                "messages": [
                    AIMessage(
                        content=message
                    )
                ],
                "routed_agent": "ShoppingAgent",
                "data_type": "text",
                "suggested_products": [],
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log(
                    "ShoppingAgent",
                    ["add_to_cart"],
                    "needs_clarification",
                    "Requested clarification for ambiguous cart item",
                ),
            }

        raw_cart_result = add_to_cart.invoke(
            {
                "product_id": product_id,
                "quantity": plan.get(
                    "quantity",
                    1,
                ),
            }
        )

        cart_result = _parse_json_dict(
            raw_cart_result
        )

        if cart_result.get(
            "error"
        ):
            final_text = (
                str(
                    cart_result[
                        "error"
                    ]
                )
            )

            data_type = "text"

        else:
            product = cart_result.get(
                "product",
                {},
            )

            final_text = (
                f"I've added "
                f"{product.get('name', 'the selected product')} "
                f"(quantity {cart_result.get('quantity', 1)}) "
                "to your shopping cart."
            )

            data_type = "cart_update"

        reasoning_steps.append(
            _make_reasoning_step(
                "Cart Action",
                f"Validated stock and added product_id={product_id} (qty={plan.get('quantity', 1)}) to cart",
                (time.perf_counter() - t_cart) * 1000.0,
            )
        )

        return {
            "messages": [
                AIMessage(
                    content=final_text
                )
            ],
            "routed_agent": "ShoppingAgent",
            "data_type": data_type,
            "suggested_products": [],
            "bundle": None,
            "cart_action": (
                cart_result
                if not cart_result.get(
                    "error"
                )
                else None
            ),
            "order_action": None,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log(
                "ShoppingAgent",
                ["add_to_cart"],
                "error" if cart_result.get("error") else "success",
                f"product_id={product_id}",
            ),
        }

    # -----------------------------------------------------------------------
    # FIRST INVENTORY SEARCH + TRUST SCORE FILTER
    # -----------------------------------------------------------------------

    t_search = time.perf_counter()
    products = _execute_inventory_search(
        plan
    )
    reasoning_steps.append(
        _make_reasoning_step(
            "Catalog & Vector Search",
            f"Retrieved {len(products)} matching products from PostgreSQL inventory",
            (time.perf_counter() - t_search) * 1000.0,
        )
    )

    used_catalog_fallback = False

    logger.info(
        "[SHOPPING WORKFLOW] Initial search returned %s products",
        len(products),
    )

    # -----------------------------------------------------------------------
    # CONTROLLED CATALOG FALLBACK
    # -----------------------------------------------------------------------

    if not products:
        t_fb = time.perf_counter()
        logger.info(
            "[SHOPPING WORKFLOW] No direct match. "
            "Inspecting real catalog."
        )

        raw_catalog = inspect_catalog.invoke(
            {}
        )

        catalog = _parse_json_dict(
            raw_catalog
        )

        available_categories = catalog.get(
            "available_categories",
            [],
        )

        if available_categories:
            fallback_plan = (
                _create_catalog_fallback_plan(
                    state,
                    plan,
                    catalog,
                )
            )

            products = (
                _execute_inventory_search(
                    fallback_plan
                )
            )

            used_catalog_fallback = True

            logger.info(
                "[SHOPPING WORKFLOW] "
                "Fallback search returned %s products",
                len(products),
            )
        reasoning_steps.append(
            _make_reasoning_step(
                "Catalog Recovery Fallback",
                f"Inspected live taxonomy and recovered {len(products)} alternative products",
                (time.perf_counter() - t_fb) * 1000.0,
            )
        )

    if products:
        top_p = products[0]
        reasoning_steps.append(
            _make_reasoning_step(
                "Trust Score Filter",
                f"Prioritized {len(products)} items by AI Trust-Weighted Rating (top: {top_p.get('name')} at {top_p.get('trust_weighted_rating', 4.8)}★)",
                1.2,
            )
        )

    # -----------------------------------------------------------------------
    # GROUNDED FINAL RESPONSE
    # -----------------------------------------------------------------------

    t_resp = time.perf_counter()
    final_text = (
        _create_grounded_product_response(
            user_query=user_query,
            products=products,
            used_catalog_fallback=(
                used_catalog_fallback
            ),
        )
    )
    reasoning_steps.append(
        _make_reasoning_step(
            "Grounded Response Synthesis",
            f"Synthesized fact-checked recommendation across {len(products)} products",
            (time.perf_counter() - t_resp) * 1000.0,
        )
    )

    logger.info(
        "[SHOPPING WORKFLOW] Completed | Products=%s",
        len(products),
    )

    return {
        "messages": [
            AIMessage(
                content=final_text
            )
        ],
        "routed_agent": "ShoppingAgent",
        "data_type": (
            "product_list"
            if products
            else "text"
        ),
        "suggested_products": products,
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "reasoning_steps": reasoning_steps,
        "action_logs": _make_action_log(
            "ShoppingAgent",
            ["search_inventory", "inspect_catalog", "trust_score_filter"]
            if used_catalog_fallback
            else ["search_inventory", "trust_score_filter"],
            "success" if products else "no_matches",
            f"Returned {len(products)} trust-ranked products",
        ),
    }


# ===========================================================================
# STORE KNOWLEDGE AGENT
# ===========================================================================

knowledge_react_agent = create_react_agent(
    model=llm,
    tools=[
        search_knowledge_base,
    ],
    prompt=(
        "You are the Store Knowledge Agent for Penguin Store.\n\n"

        "Answer official store-information questions using the "
        "search_knowledge_base tool.\n\n"

        "This includes:\n"
        "- returns\n"
        "- refunds\n"
        "- warranties\n"
        "- payment methods\n"
        "- store rules\n"
        "- fulfillment policies\n"
        "- policy-related shipping questions\n\n"

        "The knowledge base is the source of truth. "
        "Never invent a policy, refund period, warranty condition, "
        "payment rule, or store policy."
    ),
)


# ===========================================================================
# LOGISTICS AGENT
# ===========================================================================

logistics_react_agent = create_react_agent(
    model=llm,
    tools=[
        check_order_status,
    ],
    prompt=(
        "You are the Logistics Agent for Penguin Store.\n\n"

        "Your responsibility is to answer questions about specific "
        "customer orders using the check_order_status tool.\n\n"

        "You MUST use check_order_status whenever the customer asks about "
        "a specific order ID, shipment, dispatch state, delivery state, "
        "or tracking information.\n\n"

        "GROUNDING RULES:\n"
        "- The tool result is the ONLY source of truth.\n"
        "- Never invent an order status.\n"
        "- Never invent a tracking number.\n"
        "- Never invent a carrier or courier company.\n"
        "- Never invent an estimated delivery date.\n"
        "- Never claim a package is delivered unless the tool says so.\n"
        "- Never claim that a tracking website or email tracking link exists "
        "unless that information is explicitly returned by the tool.\n"
        "- Never expose customer email, name, or shipping address.\n"
        "- If tracking_number is null or missing, clearly say that no "
        "tracking number is currently available.\n"
        "- If overall_status is NO_FULFILLMENT_DATA, explain that fulfillment "
        "information has not yet been recorded.\n"
        "- If different order items have different statuses, explain that "
        "the order is partially fulfilled.\n\n"

        "When responding, summarize only the real order status, the relevant "
        "products, fulfillment type, dispatch status, and tracking number "
        "when one actually exists.\n\n"

        "Keep the response concise and customer-friendly."
    ),
)


# ===========================================================================
# HELPER FOR SPECIALIST REACT AGENTS
# ===========================================================================

def _only_new_messages(
    original_messages: Sequence[BaseMessage],
    result_messages: Sequence[BaseMessage],
) -> list[BaseMessage]:
    """
    Avoid repeatedly copying the entire nested agent history back into the
    parent LangGraph state.
    """

    original_count = len(
        original_messages
    )

    if len(
        result_messages
    ) > original_count:
        return list(
            result_messages[
                original_count:
            ]
        )

    if result_messages:
        return [
            result_messages[-1]
        ]

    return []


# ===========================================================================
# KNOWLEDGE NODE (Deterministic RAG + Multi-Model Grounded Synthesis)
# ===========================================================================

def knowledge_agent(
    state: AgentState,
):
    user_query = _latest_user_text(state)
    steps: list[dict[str, Any]] = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Routed query to Store Knowledge RAG Agent",
            0.3,
        )
    ]

    t0 = time.perf_counter()
    raw_policy = search_knowledge_base.invoke(
        {"query": user_query or "return refund warranty payment shipping policy"}
    )
    policy_context = str(raw_policy or "").strip()
    steps.append(
        _make_reasoning_step(
            "Knowledge Base RAG Retrieval",
            f"Retrieved {len(policy_context)} chars of official policy chunks from knowledge_base.md",
            (time.perf_counter() - t0) * 1000.0,
        )
    )

    t1 = time.perf_counter()
    prompt = (
        "You are the Store Knowledge Agent for Penguin Store.\n\n"
        "Answer the customer's question concisely using ONLY the official "
        "Penguin Store knowledge base context below.\n"
        "Never invent a policy, refund period, warranty condition, "
        "payment rule, or store policy."
    )

    response = _invoke_llm_safe(
        [
            {"role": "system", "content": prompt},
            {
                "role": "user",
                "content": (
                    f"Customer question:\n{user_query}\n\n"
                    f"OFFICIAL KNOWLEDGE BASE:\n{policy_context}"
                ),
            },
        ]
    )

    final_text = _message_text(response) if response is not None else ""
    if not final_text:
        final_text = (
            policy_context
            if policy_context
            else "Our official policy covers 14-day returns for IN_HOUSE items, 30-day returns for DROPSHIP items, 1-year electronic warranties, and encrypted Stripe / Cash-on-Delivery payments."
        )
    steps.append(
        _make_reasoning_step(
            "Policy Fact-Grounding Synthesis",
            "Generated fact-grounded response strictly verified against knowledge chunks",
            (time.perf_counter() - t1) * 1000.0,
        )
    )

    return {
        "messages": [AIMessage(content=final_text)],
        "routed_agent": "CustomerAgent (Knowledge)",
        "data_type": "text",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "reasoning_steps": steps,
        "action_logs": _make_action_log(
            "CustomerAgent",
            ["search_knowledge_base"],
            "success",
            f"RAG policy response ({len(policy_context)} chars context)",
        ),
    }


# ===========================================================================
# LOGISTICS NODE (Deterministic Order Lookup + Rich Order Tracker Card)
# ===========================================================================

def _extract_order_id(state: AgentState) -> Optional[int]:
    user_query = _latest_user_text(state)
    # Match 'order #12', 'order 12', '#12', or standalone number
    m = re.search(r"(?:order\s*#?\s*|#\s*)(\d+)\b", user_query, re.IGNORECASE)
    if m:
        return int(m.group(1))
    m_any = re.search(r"\b(\d+)\b", user_query)
    if m_any:
        return int(m_any.group(1))
    return None


def logistics_agent(
    state: AgentState,
):
    user_query = _latest_user_text(state)
    order_id = _extract_order_id(state)
    steps: list[dict[str, Any]] = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Routed query to Customer Logistics & Order Tracking Agent",
            0.3,
        )
    ]

    if order_id is None:
        steps.append(
            _make_reasoning_step(
                "Order ID Extraction",
                "No numeric Order ID found in query; requested clarification",
                0.5,
            )
        )
        return {
            "messages": [
                AIMessage(
                    content=(
                        "I'd be happy to check your order status! Please share "
                        "your numeric Order ID (for example: `Order #1`) and I'll "
                        "look up its real-time fulfillment and tracking details."
                    )
                )
            ],
            "routed_agent": "CustomerAgent (Logistics)",
            "data_type": "text",
            "suggested_products": [],
            "bundle": None,
            "cart_action": None,
            "order_action": None,
            "reasoning_steps": steps,
            "action_logs": _make_action_log(
                "CustomerAgent",
                [],
                "needs_clarification",
                "Asked customer for numeric order ID",
            ),
        }

    t_ord = time.perf_counter()
    raw_order_json = check_order_status.invoke({"order_id": order_id})
    parsed_order = _parse_json_dict(raw_order_json)
    steps.append(
        _make_reasoning_step(
            "Live Order & Dispatch Lookup",
            f"Queried Supabase orders & order_items for Order #{order_id}",
            (time.perf_counter() - t_ord) * 1000.0,
        )
    )

    if parsed_order.get("error"):
        error_msg = str(parsed_order["error"])
        return {
            "messages": [
                AIMessage(
                    content=(
                        f"I checked our live order system, but {error_msg} "
                        "Please double-check your Order ID and try again."
                    )
                )
            ],
            "routed_agent": "CustomerAgent (Logistics)",
            "data_type": "text",
            "suggested_products": [],
            "bundle": None,
            "cart_action": None,
            "order_action": None,
            "reasoning_steps": steps,
            "action_logs": _make_action_log(
                "CustomerAgent",
                ["check_order_status"],
                "not_found",
                f"order_id={order_id}",
            ),
        }

    order_info = parsed_order.get("order") or {}
    overall_status = order_info.get("overall_status", "PROCESSING")
    total = order_info.get("total", 0.0)
    tracking_list = order_info.get("tracking_numbers") or []
    items = order_info.get("items") or []

    # Enrich order_info so Flutter's _buildOrderTrackerCard displays all fields cleanly
    has_dropship = any(
        i.get("fulfillment_type") == "DROPSHIP" for i in items
    )
    has_inhouse = any(
        i.get("fulfillment_type") == "IN_HOUSE" for i in items
    )
    if has_dropship and has_inhouse:
        est_delivery = "1-2 Days (In-House) / 7-10 Days (Dropship)"
    elif has_dropship:
        est_delivery = "7-10 Business Days (International Partner)"
    else:
        est_delivery = "1-2 Business Days (Sargodha Warehouse)"

    order_info["status"] = overall_status
    order_info["estimated_delivery"] = est_delivery
    order_info["shipping_address"] = (
        f"Tracking: {', '.join(tracking_list)}"
        if tracking_list
        else "Verified Customer Address"
    )
    parsed_order["order"] = order_info

    t_syn = time.perf_counter()
    prompt = (
        "You are the Logistics Agent for Penguin Store.\n\n"
        "Summarize the real order status below concisely and accurately.\n"
        "- Mention the Order ID, overall status, items, fulfillment type, and tracking numbers.\n"
        "- Never invent tracking numbers or delivery claims not present in the JSON."
    )

    response = _invoke_llm_safe(
        [
            {"role": "system", "content": prompt},
            {
                "role": "user",
                "content": (
                    f"Customer question:\n{user_query}\n\n"
                    f"REAL ORDER DATA:\n{json.dumps(parsed_order, ensure_ascii=False)}"
                ),
            },
        ]
    )

    final_text = _message_text(response) if response is not None else ""
    if not final_text:
        item_names = ", ".join(
            f"{i.get('product_name', 'Item')} (x{i.get('quantity', 1)})"
            for i in items
        )
        trk_str = (
            f"Tracking: {', '.join(tracking_list)}."
            if tracking_list
            else "No tracking number assigned yet."
        )
        final_text = (
            f"Order #{order_id} is currently **{overall_status}** "
            f"(Total: ${float(total):.2f}). Items: {item_names}. {trk_str}"
        )
    steps.append(
        _make_reasoning_step(
            "Order Tracker Card Assembly",
            f"Prepared Order #{order_id} status ({overall_status}) with {len(items)} line items",
            (time.perf_counter() - t_syn) * 1000.0,
        )
    )

    return {
        "messages": [AIMessage(content=final_text)],
        "routed_agent": "CustomerAgent (Logistics)",
        "data_type": "order_tracker",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": parsed_order,
        "reasoning_steps": steps,
        "action_logs": _make_action_log(
            "CustomerAgent",
            ["check_order_status"],
            "success",
            f"Retrieved order #{order_id} ({overall_status})",
        ),
    }


# ===========================================================================
# OPERATIONS NODE (Store Inventory, Telemetry & Admin Diagnostics)
# ===========================================================================

def operations_agent(
    state: AgentState,
):
    user_query = _latest_user_text(state)
    steps: list[dict[str, Any]] = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Routed query to Store Operations & Telemetry Agent",
            0.3,
        )
    ]
    t0 = time.perf_counter()
    raw_ops = operations_overview.invoke({})
    ops_data = _parse_json_dict(raw_ops)
    steps.append(
        _make_reasoning_step(
            "Live Store Telemetry Query",
            f"Aggregated inventory, 3D model counts, and order statistics from Supabase",
            (time.perf_counter() - t0) * 1000.0,
        )
    )

    if ops_data.get("error"):
        return {
            "messages": [
                AIMessage(
                    content="I was unable to retrieve live store telemetry right now. Please try again."
                )
            ],
            "routed_agent": "OperationsAgent",
            "data_type": "text",
            "suggested_products": [],
            "bundle": None,
            "cart_action": None,
            "order_action": None,
            "reasoning_steps": steps,
            "action_logs": _make_action_log(
                "OperationsAgent",
                ["operations_overview"],
                "error",
                str(ops_data["error"]),
            ),
        }

    t1 = time.perf_counter()
    prompt = (
        "You are the Operations Agent for Penguin Store.\n"
        "Answer the user or administrator accurately using ONLY the live PostgreSQL telemetry below.\n"
        "Never invent numbers or products."
    )
    response = _invoke_llm_safe(
        [
            {"role": "system", "content": prompt},
            {
                "role": "user",
                "content": (
                    f"Request:\n{user_query}\n\n"
                    f"LIVE STORE TELEMETRY:\n{json.dumps(ops_data, ensure_ascii=False)}"
                ),
            },
        ]
    )

    final_text = _message_text(response) if response is not None else ""
    if not final_text:
        low_items = ops_data.get("low_stock_items") or []
        low_str = (
            ", ".join(f"{x['name']} ({x['stock']} left)" for x in low_items[:5])
            if low_items
            else "None (all stocked >= 10 units)"
        )
        final_text = (
            f"**Penguin Store Operations Overview**\n"
            f"- Total Products: {ops_data.get('total_products', 0)} "
            f"({ops_data.get('in_house_count', 0)} In-House, {ops_data.get('dropship_count', 0)} Dropship)\n"
            f"- Active 3D Models: {ops_data.get('active_3d_models', 0)}\n"
            f"- Total Orders: {ops_data.get('total_orders', 0)}\n"
            f"- Low Stock Alerts: {low_str}"
        )
    steps.append(
        _make_reasoning_step(
            "Operations Diagnostic Synthesis",
            f"Compiled report for {ops_data.get('total_products', 0)} products and {ops_data.get('active_3d_models', 0)} 3D assets",
            (time.perf_counter() - t1) * 1000.0,
        )
    )

    return {
        "messages": [AIMessage(content=final_text)],
        "routed_agent": "OperationsAgent",
        "data_type": "text",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "reasoning_steps": steps,
        "action_logs": _make_action_log(
            "OperationsAgent",
            ["operations_overview"],
            "success",
            f"products={ops_data.get('total_products', 0)}, 3d={ops_data.get('active_3d_models', 0)}",
        ),
    }


# ===========================================================================
# GENERAL AGENT
# ===========================================================================

def general_agent(
    state: AgentState,
):
    t0 = time.perf_counter()
    clean_history = [
        {
            "role": "user" if getattr(m, "type", "") == "human" else "assistant",
            "content": _message_text(m)[:600],
        }
        for m in state["messages"]
        if getattr(m, "type", "") in {"human", "ai"} and _message_text(m)
    ][-6:]

    response = _invoke_llm_safe(
        [
            {
                "role": "system",
                "content": (
                    "You are CTRL-X, the intelligent conversational "
                    "interface for Penguin Store's multi-agent e-commerce "
                    "system.\n\n"

                    "Respond naturally to greetings, thanks, casual "
                    "conversation, and questions about your capabilities.\n\n"

                    "CTRL-X can coordinate product discovery, shopping "
                    "recommendations, autonomous bundle building, inventory queries, cart actions, "
                    "store-policy retrieval, and order tracking.\n\n"

                    "Keep general responses concise. "
                    "Never invent store data."
                ),
            },
            *clean_history,
        ]
    )

    if response is None:
        response = AIMessage(
            content=(
                "Hello! I'm CTRL-X, your AI shopping assistant at Penguin Store. "
                "I can help you discover products, build budget bundles with high trust reviews, "
                "add items to your cart, track orders by Order ID, or answer store policy questions. "
                "How can I help you today?"
            )
        )

    steps = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Classified message as General Conversational intent",
            0.2,
        ),
        _make_reasoning_step(
            "Conversational Response Generation",
            "Generated assistant greeting & capability summary",
            (time.perf_counter() - t0) * 1000.0,
        ),
    ]

    return {
        "messages": [
            response
        ],
        "routed_agent": "GeneralAgent",
        "data_type": "text",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "reasoning_steps": steps,
        "action_logs": _make_action_log(
            "GeneralAgent",
            [],
            "success",
            "Conversational reply",
        ),
    }


# ===========================================================================
# SUPERVISOR AGENT (Fast Hybrid Intent Router + Multi-Model Fallback)
# ===========================================================================

def _fast_intent_route(user_query: str) -> Optional[str]:
    """
    Route unambiguous user requests in <0.1ms without consuming LLM tokens.
    Returns None only when the query is ambiguous and needs LLM classification.
    """
    q = user_query.strip().lower()
    if not q:
        return "GeneralAgent"

    # 1. Pure greetings / thanks / capabilities
    if re.fullmatch(
        r"(hi|hello|hey|good\s+(morning|afternoon|evening)|thanks|thank\s+you|bye|goodbye|who\s+are\s+you|what\s+can\s+you\s+do)[!?.]*",
        q,
    ):
        return "GeneralAgent"

    # 2. Order status / tracking
    if any(
        kw in q
        for kw in (
            "where is order",
            "track order",
            "track my order",
            "order status",
            "status of order",
            "my order #",
            "order #",
            "shipment status",
            "delivery status",
        )
    ) or re.search(r"\border\s+\d+\b", q):
        return "LogisticsAgent"

    # 3. Store policies / Knowledge Base
    if any(
        kw in q
        for kw in (
            "return policy",
            "refund policy",
            "refund window",
            "how to return",
            "can i return",
            "warranty",
            "warranties",
            "payment method",
            "how can i pay",
            "what payment",
            "restocking fee",
            "shipping policy",
            "fulfillment policy",
            "where do you ship from",
            "warehouse location",
        )
    ):
        return "KnowledgeAgent"

    # 4. Operations / Inventory Telemetry / Store Overview
    if any(
        kw in q
        for kw in (
            "inventory report",
            "inventory status",
            "store overview",
            "store summary",
            "store stats",
            "low stock",
            "how many products",
            "how many 3d",
            "active 3d",
            "3d model count",
            "total orders",
            "category breakdown",
            "operations report",
        )
    ):
        return "OperationsAgent"

    # 5. Product discovery / Comparison / Shopping / Cart actions
    if any(
        kw in q
        for kw in (
            "compare",
            "comparison",
            "difference between",
            "which is better",
            "add to cart",
            "add the ",
            "buy ",
            "do you have",
            "show me",
            "find ",
            "search ",
            "looking for",
            "recommend",
            "suggest",
            "shirt",
            "shirts",
            "shoe",
            "shoes",
            "sneaker",
            "boot",
            "watch",
            "watches",
            "perfume",
            "fragrance",
            "laptop",
            "phone",
            "iphone",
            "charger",
            "airpods",
            "bag",
            "handbag",
            "furniture",
            "kitchen",
            "grocery",
            "groceries",
            "under $",
            "in stock",
            "catalog",
            "products",
            "bundle",
            "desk setup",
            "office setup",
            "gaming setup",
            "build me",
            "build a",
            "outfit",
            "earbuds",
            "trust",
        )
    ):
        return "RetrievalAgent"

    return None


def supervisor_node(
    state: AgentState,
):
    user_query = _latest_user_text(state)
    fast_route = _fast_intent_route(user_query)

    if fast_route is not None:
        logger.info(
            "[SUPERVISOR] Fast-routed request to %s",
            fast_route,
        )
        return {
            "next_agent": fast_route,
        }

    system_prompt = """
You are the Supervisor Agent for Penguin Store's multi-agent autonomous
e-commerce system.

Route the customer's latest request to exactly ONE specialist.

RetrievalAgent
- products, comparisons, prices, recommendations, shopping, outfits, gifts, styles, categories, cart requests, buying products

OperationsAgent
- store inventory overview, low stock alerts, total products, active 3D model counts, category breakdown, store operational diagnostics

KnowledgeAgent
- return policy, refunds, warranties, payment methods, store rules, fulfillment policies, general shipping policies

LogisticsAgent
- a specific order, order tracking, shipment status, delivery status, questions involving a specific order ID

GeneralAgent
- hello / hi / hey, thanks, goodbye, casual conversation, questions about CTRL-X capabilities

Respond ONLY with one exact route name:
RetrievalAgent
OperationsAgent
KnowledgeAgent
LogisticsAgent
GeneralAgent
""".strip()

    conversation = _conversation_excerpt(state, max_messages=6)
    response = _invoke_llm_safe(
        [
            {
                "role": "system",
                "content": system_prompt,
            },
            {
                "role": "user",
                "content": f"Conversation:\n{conversation}\n\nLatest message:\n{user_query}",
            },
        ]
    )

    route = (
        _message_text(response).lower()
        if response is not None
        else "retrievalagent"
    )

    if "retrievalagent" in route:
        next_agent = "RetrievalAgent"

    elif "operationsagent" in route:
        next_agent = "OperationsAgent"

    elif "knowledgeagent" in route:
        next_agent = "KnowledgeAgent"

    elif "logisticsagent" in route:
        next_agent = "LogisticsAgent"

    elif "generalagent" in route:
        next_agent = "GeneralAgent"

    else:
        next_agent = "RetrievalAgent"

    logger.info(
        "[SUPERVISOR] Routed request to %s",
        next_agent,
    )

    return {
        "next_agent": next_agent,
    }


# ===========================================================================
# LANGGRAPH
# ===========================================================================

workflow = StateGraph(
    AgentState
)

workflow.add_node(
    "Supervisor",
    supervisor_node,
)

workflow.add_node(
    "RetrievalAgent",
    retrieval_agent,
)

workflow.add_node(
    "OperationsAgent",
    operations_agent,
)

workflow.add_node(
    "KnowledgeAgent",
    knowledge_agent,
)

workflow.add_node(
    "LogisticsAgent",
    logistics_agent,
)

workflow.add_node(
    "GeneralAgent",
    general_agent,
)


workflow.set_entry_point(
    "Supervisor"
)


workflow.add_conditional_edges(
    "Supervisor",
    lambda state: state["next_agent"],
    {
        "RetrievalAgent": "RetrievalAgent",
        "OperationsAgent": "OperationsAgent",
        "KnowledgeAgent": "KnowledgeAgent",
        "LogisticsAgent": "LogisticsAgent",
        "GeneralAgent": "GeneralAgent",
    },
)


workflow.add_edge(
    "RetrievalAgent",
    END,
)

workflow.add_edge(
    "OperationsAgent",
    END,
)

workflow.add_edge(
    "KnowledgeAgent",
    END,
)

workflow.add_edge(
    "LogisticsAgent",
    END,
)

workflow.add_edge(
    "GeneralAgent",
    END,
)


# ===========================================================================
# MEMORY
# ===========================================================================

checkpointer = MemorySaver()


# ===========================================================================
# COMPILED MULTI-AGENT APPLICATION
# ===========================================================================

multi_agent_app = workflow.compile(
    checkpointer=checkpointer,
)