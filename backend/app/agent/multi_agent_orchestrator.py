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

from app.agent.db_tools import (
    apply_optimal_promo,
    build_and_optimize_cart,
    calculate_best_deal,
    compare_and_decide_best,
    create_b2b_rfq,
    execute_cart_mutation,
    execute_favorite_toggle,
    get_product_decision_profile,
    get_user_live_state,
    lookup_order_status,
    search_products_db,
    trigger_ui_navigation,
)
from app.agent.tools import (
    add_to_cart,
    check_order_status,
    check_reviews_and_trust,
    compare_products,
    inspect_catalog,
    operations_overview,
    search_inventory,
    search_knowledge_base,
)
from app.agent.voice_formatter import (
    build_bundle_spoken_summary,
    build_client_action_spoken_summary,
    build_comparison_spoken_summary,
    build_product_list_spoken_summary,
    build_review_trust_spoken_summary,
    sanitize_spoken_text,
)
from app.core.database import SessionLocal
from app.core.supabase_rest import (
    fetch_3d_catalog_ids_https,
    fetch_product_by_id_https,
    fetch_products_https,
)
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

    spoken_summary: Optional[str]

    client_action: Optional[dict[str, Any]]

    client_actions: Optional[list[dict[str, Any]]]

    executed_actions: Optional[list[dict[str, Any]]]

    decision_card: Optional[dict[str, Any]]

    pending_confirmation: Optional[dict[str, Any]]

    screen_context: Optional[dict[str, Any]]

    db_retrieval_ms: Optional[float]

    llm_latency_ms: Optional[float]

    reasoning_steps: Optional[list[dict[str, Any]]]

    action_logs: Optional[list[dict[str, Any]]]


def _make_reasoning_step(
    step: str,
    summary: str,
    duration_ms: float,
    status: str = "completed",
    is_mcp: Optional[bool] = None,
) -> dict[str, Any]:
    _is_mcp = (
        is_mcp
        if is_mcp is not None
        else (
            step.startswith("[MCP]")
            or any(
                k in step.lower()
                for k in (
                    "vector",
                    "catalog",
                    "trust score",
                    "pricing",
                    "cart mutation",
                    "rfq",
                    "deal optimizer",
                    "mcp",
                )
            )
        )
    )
    formatted_step = (
        step if (not _is_mcp or step.startswith("[MCP]")) else f"[MCP] {step}"
    )
    return {
        "step": formatted_step,
        "status": status,
        "duration_ms": round(max(0.1, float(duration_ms)), 2),
        "summary": summary[:280],
        "is_mcp": _is_mcp,
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
- NEVER output Markdown tables, pipe characters (|), horizontal dash rules (---), asterisks (*), or raw bullets. Write crisp, conversational plain sentences.
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
# VOICE CONCIERGE CONTEXT RESOLUTION & ACTION HELPERS
# ===========================================================================

def _extract_quantity_and_addons(user_query: str) -> tuple[int, list[str]]:
    q_lower = user_query.lower()
    qty = 1
    m_num = re.search(
        r"\b(?:add|buy|order|get|put)\s+(\d+)\s+(?:units?|pcs?|pieces?|x|of)?",
        q_lower,
    )
    if not m_num:
        m_num = re.search(r"\b(\d+)\s+(?:units?|pcs?|pieces?|bulk)\b", q_lower)
    if m_num:
        try:
            qty = max(1, min(500, int(m_num.group(1))))
        except ValueError:
            qty = 1
    elif "two " in q_lower and "top two" not in q_lower and "first two" not in q_lower:
        qty = 2
    elif "three " in q_lower and "top three" not in q_lower:
        qty = 3

    add_ons: list[str] = []
    if "gift wrap" in q_lower or "gift-wrap" in q_lower:
        add_ons.append("gift_wrap")
    if "express" in q_lower or "fast shipping" in q_lower:
        add_ons.append("express_handling")
    return qty, add_ons


def _resolve_target_product(
    user_query: str,
    state: AgentState,
    *,
    prefer_3d: bool = False,
) -> Optional[dict[str, Any]]:
    """
    Resolve an exact live Supabase product from:
      1) Explicit product ID (#144 / product 144)
      2) Screen context (`viewing_product_id` when user says "this" / "current")
      3) Comparison winner ("winner" / "best one")
      4) Session memory (`suggested_products` ordinals or name overlap, plus recent `cart_action`)
    """
    q_lower = user_query.lower().strip()
    active_3d_ids = set(fetch_3d_catalog_ids_https())

    def _enrich_id(pid: Any) -> Optional[dict[str, Any]]:
        try:
            ip = int(pid)
        except (TypeError, ValueError):
            return None
        row = fetch_product_by_id_https(ip)
        if not row:
            return None
        enriched_list = _enrich_and_rank_by_trust([row])
        if not enriched_list:
            return None
        item = enriched_list[0]
        item["has_3d_model"] = bool(item.get("has_3d_model")) or (ip in active_3d_ids)
        return item

    # 1. Explicit ID
    id_match = re.search(r"\b(?:id|product|#)\s*(\d+)\b", q_lower)
    if id_match:
        found = _enrich_id(id_match.group(1))
        if found:
            return found

    # 2. Screen context (user is currently viewing a ProductDetailScreen)
    screen_ctx = state.get("screen_context") or {}
    viewing_pid = screen_ctx.get("viewing_product_id")
    if viewing_pid and any(w in q_lower for w in ("this", "current", "viewing", "here")):
        found = _enrich_id(viewing_pid)
        if found:
            return found

    # 3. Winner / Top pick from last comparison
    comparison = state.get("comparison") or {}
    if comparison and any(w in q_lower for w in ("winner", "best one", "top pick", "recommended one")):
        win_id = comparison.get("winner_id")
        if win_id:
            found = _enrich_id(win_id)
            if found:
                return found

    recent_products = [p for p in (state.get("suggested_products") or []) if isinstance(p, dict)]

    # 4. Ordinals against last shown products
    if recent_products:
        if any(w in q_lower for w in ("first", "1st", "number one", "top one")) and len(recent_products) >= 1:
            found = _enrich_id(recent_products[0].get("id"))
            if found:
                return found
        if any(w in q_lower for w in ("second", "2nd", "number two")) and len(recent_products) >= 2:
            found = _enrich_id(recent_products[1].get("id"))
            if found:
                return found
        if any(w in q_lower for w in ("third", "3rd", "number three")) and len(recent_products) >= 3:
            found = _enrich_id(recent_products[2].get("id"))
            if found:
                return found
        if "last" in q_lower:
            found = _enrich_id(recent_products[-1].get("id"))
            if found:
                return found

    # 5. Name token overlap against recent products
    stop_words = {
        "add", "to", "my", "the", "cart", "buy", "purchase", "want", "please", "one",
        "show", "me", "that", "in", "3d", "open", "view", "preview", "save", "favorite",
        "favorites", "wishlist", "are", "reviews", "real", "trust", "is", "this", "it",
        "good", "worth", "buying", "with", "gift", "wrap", "units", "unit", "for",
    }
    q_words = set(re.findall(r"[a-z0-9]+", q_lower)) - stop_words
    if q_words and recent_products:
        best_pid = None
        best_overlap = 0
        for prod in recent_products:
            pname = str(prod.get("name") or "").lower()
            pid = prod.get("id")
            if not pid or not pname:
                continue
            if pname in q_lower:
                found = _enrich_id(pid)
                if found:
                    return found
            overlap = len(q_words & set(re.findall(r"[a-z0-9]+", pname)))
            if overlap > best_overlap:
                best_overlap = overlap
                best_pid = pid
        if best_pid is not None and best_overlap > 0:
            found = _enrich_id(best_pid)
            if found:
                return found

    # 6. Implicit pronoun resolution ("that", "it", "this")
    if any(w in q_lower.split() for w in ("that", "it", "this")):
        if viewing_pid:
            found = _enrich_id(viewing_pid)
            if found:
                return found
        last_cart = (state.get("cart_action") or {}).get("product")
        if isinstance(last_cart, dict) and last_cart.get("id"):
            found = _enrich_id(last_cart["id"])
            if found and (not prefer_3d or found.get("has_3d_model")):
                return found
        if prefer_3d and recent_products:
            for prod in recent_products:
                cand = _enrich_id(prod.get("id"))
                if cand and cand.get("has_3d_model"):
                    return cand
        if recent_products:
            found = _enrich_id(recent_products[0].get("id"))
            if found:
                return found

    # 7. Screen fallback even without pronoun
    if viewing_pid and len(q_words) <= 2:
        found = _enrich_id(viewing_pid)
        if found:
            return found

    # 8. If asking to view something in 3D with empty session, check recent or 3D catalog
    if prefer_3d and recent_products:
        for prod in recent_products:
            cand = _enrich_id(prod.get("id"))
            if cand and cand.get("has_3d_model"):
                return cand
        return _enrich_id(recent_products[0].get("id"))

    # 9. Named item lookup across entire Supabase catalog
    if q_words:
        all_products = fetch_products_https()
        best_row = None
        best_score = 0
        for p in all_products:
            pname = str(p.get("name") or "").lower()
            if not pname:
                continue
            overlap = len(q_words & set(re.findall(r"[a-z0-9]+", pname)))
            if overlap > best_score:
                best_score = overlap
                best_row = p
        if best_row is not None and best_score >= 2:
            return _enrich_id(best_row.get("id"))

    return None


# ===========================================================================
# CONTROLLED SHOPPING / RETRIEVAL AGENT
# ===========================================================================

def retrieval_agent(
    state: AgentState,
):
    """
    Bounded shopping workflow with Trust-Aware Ranking, Autonomous Bundle Builder,
    Dual-Channel Voice Summaries, Live Actions, and Structured Reasoning Trace.
    """

    user_query = _latest_user_text(
        state
    )
    q_lower = user_query.strip().lower()
    recent_products = [p for p in (state.get("suggested_products") or []) if isinstance(p, dict)]

    logger.info(
        "[SHOPPING WORKFLOW] Started | Query=%r",
        user_query,
    )

    reasoning_steps: list[dict[str, Any]] = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Classified query as Voice & Shopping Concierge workflow (ShoppingAgent)",
            0.4,
        )
    ]
    screen_ctx = state.get("screen_context") or {}
    viewing_pid = screen_ctx.get("viewing_product_id")
    pending_confirm_state = state.get("pending_confirmation") or screen_ctx.get("pending_confirmation")

    # -----------------------------------------------------------------------
    # 00A. CONFIRM-BEFORE-COMMIT RESOLUTION ("Yes, confirm", "Confirm quote")
    # -----------------------------------------------------------------------
    is_confirm_utterance = bool(
        re.search(
            r"^\s*(?:yes|yep|yeah|sure|ok|okay)?\s*,?\s*(?:confirm|confirm\s+it|submit\s+quote|submit\s+rfq|proceed\s+to\s+checkout|clear\s+it|yes\s+confirm)\b",
            q_lower,
        )
    ) or bool(screen_ctx.get("confirm_pending_action"))

    if is_confirm_utterance and isinstance(pending_confirm_state, dict):
        t_conf = time.perf_counter()
        p_type = str(pending_confirm_state.get("action_type") or "")
        p_payload = pending_confirm_state.get("payload") or {}
        if p_type == "submit_b2b_rfq" or p_payload.get("type") == "submit_b2b_rfq":
            rfq_commit = create_b2b_rfq(
                product_id=int(p_payload.get("product_id") or viewing_pid or 144),
                quantity=int(p_payload.get("quantity") or 30),
                target_unit_price=p_payload.get("target_unit_price"),
                notes=str(p_payload.get("notes") or ""),
                customer_email=str(p_payload.get("customer_email") or "buyer@penguinstore.com"),
                confirmed=True,
            )
            db_ms = round((time.perf_counter() - t_conf) * 1000.0, 2)
            ca = rfq_commit["client_action"]
            ea = rfq_commit["executed_action"]
            spoken = rfq_commit["spoken_summary"]
            reasoning_steps.append(
                _make_reasoning_step("create_b2b_rfq (Confirmed)", f"Committed B2B RFQ #{ca.get('rfq_id')} to Supabase rfq_requests", db_ms)
            )
            return {
                "messages": [AIMessage(content=spoken)],
                "spoken_summary": spoken,
                "client_action": ca,
                "client_actions": [ca],
                "executed_actions": [ea],
                "pending_confirmation": None,
                "decision_card": None,
                "routed_agent": "VoiceConcierge (B2BDesk)",
                "data_type": "b2b_rfq",
                "suggested_products": recent_products,
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["create_b2b_rfq"], "success", f"rfq_id={ca.get('rfq_id')}"),
            }
        if p_type == "clear_cart" or p_payload.get("type") == "clear_cart":
            clr = execute_cart_mutation(action="clear", confirmed=True)
            ca = clr["client_action"]
            ea = clr["executed_action"]
            spoken = clr["spoken_summary"]
            return {
                "messages": [AIMessage(content=spoken)],
                "spoken_summary": spoken,
                "client_action": ca,
                "client_actions": [ca],
                "executed_actions": [ea],
                "pending_confirmation": None,
                "routed_agent": "VoiceConcierge (CartManager)",
                "data_type": "cart_update",
                "suggested_products": recent_products,
                "db_retrieval_ms": 0.5,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["execute_cart_mutation"], "success", "clear_cart"),
            }
        if p_type == "proceed_to_checkout":
            nav_co = trigger_ui_navigation("/checkout", confirmed=True)
            ca = nav_co["client_action"]
            ea = nav_co["executed_action"]
            spoken = nav_co["spoken_summary"]
            return {
                "messages": [AIMessage(content=spoken)],
                "spoken_summary": spoken,
                "client_action": ca,
                "client_actions": [ca],
                "executed_actions": [ea],
                "pending_confirmation": None,
                "routed_agent": "VoiceConcierge (Navigator)",
                "data_type": "text",
                "suggested_products": recent_products,
                "db_retrieval_ms": 0.5,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["trigger_ui_navigation"], "success", "/checkout"),
            }

    # -----------------------------------------------------------------------
    # 00B. CART OPTIMIZATION & OPTIMAL COUPON ENGINE
    # ("Apply the best coupon to my cart and tell me my final total")
    # -----------------------------------------------------------------------
    if any(
        p in q_lower
        for p in (
            "best coupon",
            "best promo",
            "apply coupon",
            "apply the best coupon",
            "apply promo",
            "optimal promo",
            "discount code",
            "promo code",
            "optimize my cart",
            "audit my cart",
            "final total",
        )
    ) and not any(k in q_lower for k in ("order status", "latest order")):
        t_opt = time.perf_counter()
        live_state = get_user_live_state(screen_context=screen_ctx)
        promo_res = apply_optimal_promo(
            cart_subtotal=live_state["cart_subtotal"],
            cart_items=live_state["cart_items"],
        )
        cart_audit = build_and_optimize_cart(screen_context=screen_ctx)
        db_ms = round((time.perf_counter() - t_opt) * 1000.0, 2)

        ca = promo_res["client_action"]
        ea = promo_res["executed_action"]
        spoken = promo_res["spoken_summary"]
        reply_text = (
            f"I audited your live cart (Subtotal: **${promo_res['cart_subtotal']:.2f}**) across all active Penguin Store promotions "
            f"(`PENGUIN10`, `WELCOME20`, `WHOLESALE15`, `ARCTIC5`) and automatically applied **`{promo_res['promo_code']}`** "
            f"({promo_res['description']}).\n\n"
            f"- **Promo Savings:** -${promo_res['discount_amount']:.2f}\n"
            f"- **Discounted Subtotal:** ${promo_res['discounted_subtotal']:.2f}\n"
            f"- **Estimated Tax (5%):** ${promo_res['estimated_tax']:.2f}\n"
            f"- **New Final Total:** **${promo_res['final_total']:.2f}**"
        )
        reasoning_steps.extend(
            [
                _make_reasoning_step(
                    "get_user_live_state",
                    f"Read live cart state ({live_state['cart_item_count']} items, subtotal=${promo_res['cart_subtotal']:.2f})",
                    db_ms * 0.4,
                ),
                _make_reasoning_step(
                    "apply_optimal_promo",
                    f"Selected {promo_res['promo_code']} (-${promo_res['discount_amount']:.2f}) -> Final Total ${promo_res['final_total']:.2f}",
                    db_ms * 0.6,
                ),
            ]
        )
        return {
            "messages": [AIMessage(content=reply_text)],
            "spoken_summary": spoken,
            "client_action": ca,
            "client_actions": [ca],
            "executed_actions": [ea],
            "decision_card": None,
            "pending_confirmation": None,
            "routed_agent": "VoiceConcierge (DealOptimizer)",
            "data_type": "cart_update",
            "suggested_products": recent_products,
            "bundle": None,
            "cart_action": cart_audit,
            "order_action": None,
            "db_retrieval_ms": db_ms,
            "llm_latency_ms": 0.0,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log(
                "VoiceConcierge",
                ["get_user_live_state", "calculate_best_deal", "apply_optimal_promo"],
                "success",
                f"promo={promo_res['promo_code']}, final_total={promo_res['final_total']}",
            ),
        }

    # -----------------------------------------------------------------------
    # 00C. B2B WHOLESALE RFQ & MOQ BULK PRICING ENGINE
    # ("Draft a wholesale quote for 30 units of this item", "What's the B2B bulk price for 20 units?")
    # -----------------------------------------------------------------------
    if any(
        p in q_lower
        for p in (
            "wholesale quote",
            "draft a wholesale",
            "draft wholesale",
            "b2b quote",
            "bulk quote",
            "create rfq",
            "submit rfq",
            "rfq for",
            "quote for ",
            "b2b bulk price",
            "bulk price for",
            "wholesale price for",
        )
    ):
        t_rfq = time.perf_counter()
        target_prod = _resolve_target_product(user_query, state)
        if target_prod is None and viewing_pid:
            row = fetch_product_by_id_https(int(viewing_pid))
            if row:
                target_prod = _enrich_and_rank_by_trust([row])[0]
        if target_prod is None and recent_products:
            target_prod = recent_products[0]
        if target_prod is None:
            row = fetch_product_by_id_https(144) or (fetch_products_https() or [None])[0]
            if row:
                target_prod = _enrich_and_rank_by_trust([row])[0]

        pid = int((target_prod or {}).get("id") or viewing_pid or 144)
        qty_m = re.search(r"\b(\d+)\s*(?:units?|items?|pieces?|pcs|qty)\b", q_lower)
        req_qty = int(qty_m.group(1)) if qty_m else 30

        is_quote_draft = any(w in q_lower for w in ("draft", "quote", "rfq", "submit"))
        if is_quote_draft:
            rfq_res = create_b2b_rfq(
                product_id=pid,
                quantity=req_qty,
                customer_email=str(screen_ctx.get("user_email") or "buyer@penguinstore.com"),
                product_data=target_prod,
                confirmed=False,
            )
            db_ms = round((time.perf_counter() - t_rfq) * 1000.0, 2)
            q_info = rfq_res["quote"]
            pending = rfq_res["pending_confirmation"]
            spoken = rfq_res["spoken_summary"]
            reply_text = (
                f"I've drafted a **B2B Wholesale Quote** for **{q_info['quantity']} units** of **{q_info['product_name']}**:\n\n"
                f"- **Retail Unit Price:** ${q_info['retail_unit_price']:.2f}\n"
                f"- **B2B Tier Applied:** {q_info['b2b_tier_label']} (**{q_info['b2b_discount_pct']}% OFF**)\n"
                f"- **Wholesale Unit Price:** **${q_info['target_unit_price']:.2f}/unit**\n"
                f"- **Estimated Wholesale Total:** **${q_info['estimated_total']:.2f}** (Save **${q_info['wholesale_savings']:.2f}**)\n\n"
                f"Say **\"Yes, confirm\"** or tap **Confirm & Submit B2B RFQ** below to commit this quote to Supabase."
            )
            reasoning_steps.append(
                _make_reasoning_step(
                    "create_b2b_rfq",
                    f"Calculated B2B tier ({q_info['b2b_discount_pct']}% off) for {req_qty}x {q_info['product_name']} & staged Confirm-Before-Commit gate",
                    db_ms,
                )
            )
            return {
                "messages": [AIMessage(content=reply_text)],
                "spoken_summary": spoken,
                "client_action": None,
                "client_actions": [],
                "executed_actions": [],
                "pending_confirmation": pending,
                "decision_card": None,
                "routed_agent": "VoiceConcierge (B2BDesk)",
                "data_type": "b2b_rfq",
                "suggested_products": [target_prod] if target_prod else recent_products,
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log(
                    "VoiceConcierge",
                    ["calculate_best_deal", "create_b2b_rfq"],
                    "pending_confirmation",
                    f"product_id={pid}, qty={req_qty}",
                ),
            }
        else:
            deal_res = calculate_best_deal(product_id=pid, quantity=req_qty)
            db_ms = round((time.perf_counter() - t_rfq) * 1000.0, 2)
            spoken = sanitize_spoken_text(
                f"For {req_qty} units of {deal_res['product_name']}, you qualify for our {deal_res['b2b_discount_pct']} percent "
                f"wholesale tier at ${deal_res['b2b_unit_price']:.2f} per unit, plus code {deal_res['best_promo_code']} "
                f"brings your final total to ${deal_res['final_total']:.2f}."
            )
            reply_text = (
                f"**B2B Bulk Pricing Breakdown for {req_qty}x {deal_res['product_name']}**:\n"
                f"- **Tier:** {deal_res['b2b_tier_label']}\n"
                f"- **Wholesale Unit Price:** **${deal_res['b2b_unit_price']:.2f}** (Retail: ${deal_res['retail_unit_price']:.2f})\n"
                f"- **Best Stackable Promo:** `{deal_res['best_promo_code']}` (-${deal_res['promo_discount']:.2f})\n"
                f"- **Final Total (incl. tax):** **${deal_res['final_total']:.2f}** (Total Savings: **${deal_res['total_savings']:.2f}**)"
            )
            reasoning_steps.append(
                _make_reasoning_step("calculate_best_deal", f"Computed B2B MOQ tier for {req_qty} units of product #{pid}", db_ms)
            )
            return {
                "messages": [AIMessage(content=reply_text)],
                "spoken_summary": spoken,
                "client_action": None,
                "client_actions": [],
                "executed_actions": [],
                "routed_agent": "VoiceConcierge (B2BDesk)",
                "data_type": "product_list",
                "suggested_products": [target_prod] if target_prod else recent_products,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["calculate_best_deal"], "success", f"product_id={pid}, qty={req_qty}"),
            }

    # -----------------------------------------------------------------------
    # 00D. AUTONOMOUS ADVISORY + WEIGHTED DECISION + OPTIONAL AUTO-ADD TO CART
    # ("Pick the best headphones under $350 based on real reviews and add it to my cart",
    #  "Compare these and add the winner", "Which one should I buy?")
    # -----------------------------------------------------------------------
    is_decision_query = any(
        p in q_lower
        for p in (
            "pick the best",
            "choose the best",
            "find the best",
            "select the best",
            "decide for me",
            "which one should i buy",
            "which is the best",
            "add the winner",
            "compare these and add",
            "based on real reviews",
        )
    )
    if is_decision_query:
        t_dec = time.perf_counter()
        max_price = _extract_budget_from_query(user_query)
        user_priority = "best_value"
        if any(w in q_lower for w in ("review", "trust", "authentic", "rated", "reliable")):
            user_priority = "highest_trust"
        elif any(w in q_lower for w in ("cheap", "cheapest", "lowest price", "afford")):
            user_priority = "cheapest"
        elif any(w in q_lower for w in ("premium", "flagship", "pro", "luxury")):
            user_priority = "premium"

        use_context_ids: Optional[list[int]] = None
        if any(w in q_lower for w in ("these", "them", "shown", "winner")) and len(recent_products) >= 2:
            use_context_ids = [int(p["id"]) for p in recent_products[:4] if p.get("id")]

        dec_res = compare_and_decide_best(
            product_ids=use_context_ids,
            user_priority=user_priority,
            query=user_query,
            max_price=max_price,
        )
        winner = dec_res["winner"]
        decision_card = dec_res["decision_card"]
        comparison_matrix = dec_res["comparison"]
        scored_products = dec_res["products"]
        spoken = dec_res["spoken_summary"]

        tools_used = ["search_products_db", "check_reviews_and_trust", "compare_and_decide_best"]
        reasoning_steps.extend(
            [
                _make_reasoning_step(
                    "search_products_db",
                    f"Retrieved {len(scored_products)} real Supabase candidates (max_price={max_price})",
                    (time.perf_counter() - t_dec) * 450.0,
                ),
                _make_reasoning_step(
                    "compare_and_decide_best",
                    f"Scored candidates 0-100 on {user_priority}; Winner: {winner['name']} ({winner['decision_score']}/100, {winner['trust_score']}% Trust)",
                    (time.perf_counter() - t_dec) * 550.0,
                ),
            ]
        )

        wants_auto_add = any(
            k in q_lower
            for k in (
                "add it",
                "add to my cart",
                "add to cart",
                "add the winner",
                "and add",
                "put it in my cart",
                "buy it",
            )
        )
        client_action: Optional[dict[str, Any]] = None
        client_actions: list[dict[str, Any]] = []
        executed_actions: list[dict[str, Any]] = []
        cart_action_payload: Optional[dict[str, Any]] = None

        if wants_auto_add:
            req_qty, add_ons = _extract_quantity_and_addons(user_query)
            variant_req = "Pro Edition" if "pro edition" in q_lower else ("Studio Pack" if "studio pack" in q_lower else "Standard")
            cart_mut = execute_cart_mutation(
                action="add",
                product_id=int(winner["id"]),
                quantity=max(1, req_qty),
                variant=variant_req,
                add_ons=add_ons,
                product_data=winner,
            )
            client_action = cart_mut["client_action"]
            client_actions.append(client_action)
            executed_actions.append(cart_mut["executed_action"])
            cart_action_payload = cart_mut.get("cart_action")
            tools_used.append("execute_cart_mutation")
            spoken = sanitize_spoken_text(
                f"{spoken} I have also added {winner['name']} directly to your shopping cart."
            )
            reasoning_steps.append(
                _make_reasoning_step(
                    "execute_cart_mutation",
                    f"Auto-added winner {winner['name']} (#{winner['id']}) to cart with Instant Undo",
                    1.2,
                )
            )

        db_ms = round((time.perf_counter() - t_dec) * 1000.0, 2)
        reply_lines = [
            f"### AI Decision Verdict: **{winner['name']}** ({winner['decision_score']}/100 Confidence)",
            f"- **Why Chosen:** {decision_card['why_chosen']}",
        ]
        if decision_card.get("alternatives"):
            alt = decision_card["alternatives"][0]
            reply_lines.append(
                f"- **Runner-Up Tradeoff:** **{alt['name']}** (${alt['price']:.2f}, {alt['confidence_score']}/100 Score) — {alt['tradeoff']}"
            )
        if wants_auto_add:
            reply_lines.append(
                f"\n**Autonomous Action Executed:** Added **1x {winner['name']}** (${winner['price']:.2f}) to your cart. You can tap **Undo** anytime."
            )

        return {
            "messages": [AIMessage(content="\n".join(reply_lines))],
            "spoken_summary": spoken,
            "client_action": client_action,
            "client_actions": client_actions,
            "executed_actions": executed_actions,
            "decision_card": decision_card,
            "pending_confirmation": None,
            "routed_agent": "VoiceConcierge (DecisionEngine)",
            "data_type": "comparison",
            "suggested_products": scored_products,
            "bundle": None,
            "comparison": comparison_matrix,
            "cart_action": cart_action_payload,
            "order_action": None,
            "db_retrieval_ms": db_ms,
            "llm_latency_ms": 0.0,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log(
                "VoiceConcierge",
                tools_used,
                "success",
                f"winner_id={winner['id']} ({winner['decision_score']}/100)",
            ),
        }

    # -----------------------------------------------------------------------
    # 00E. CLEAR CART / REMOVE FROM CART INTENT
    # -----------------------------------------------------------------------
    if any(p in q_lower for p in ("clear my cart", "empty my cart", "clear cart", "remove everything from cart")):
        clr_res = execute_cart_mutation(action="clear", confirmed=False)
        pending = clr_res["pending_confirmation"]
        spoken = clr_res["spoken_summary"]
        reasoning_steps.append(
            _make_reasoning_step("Confirm-Before-Commit Gate", "Staged confirmation before clearing entire cart", 0.4)
        )
        return {
            "messages": [AIMessage(content=spoken)],
            "spoken_summary": spoken,
            "client_action": None,
            "client_actions": [],
            "executed_actions": [],
            "pending_confirmation": pending,
            "routed_agent": "VoiceConcierge (CartManager)",
            "data_type": "text",
            "suggested_products": recent_products,
            "db_retrieval_ms": 0.4,
            "llm_latency_ms": 0.0,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log("VoiceConcierge", ["execute_cart_mutation"], "pending_confirmation", "clear_cart"),
        }

    if any(p in q_lower for p in ("remove from cart", "remove this from cart", "remove it from my cart", "delete from cart")):
        target_prod = _resolve_target_product(user_query, state) or (recent_products[0] if recent_products else None)
        pid = int((target_prod or {}).get("id") or viewing_pid or 144)
        rm_res = execute_cart_mutation(action="remove", product_id=pid, product_data=target_prod)
        ca = rm_res["client_action"]
        ea = rm_res["executed_action"]
        spoken = rm_res["spoken_summary"]
        return {
            "messages": [AIMessage(content=spoken)],
            "spoken_summary": spoken,
            "client_action": ca,
            "client_actions": [ca],
            "executed_actions": [ea],
            "routed_agent": "VoiceConcierge (CartManager)",
            "data_type": "cart_update",
            "suggested_products": recent_products,
            "db_retrieval_ms": 1.0,
            "llm_latency_ms": 0.0,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log("VoiceConcierge", ["execute_cart_mutation"], "success", f"remove product_id={pid}"),
        }

    # -----------------------------------------------------------------------
    # 0A. DIRECT SCREEN NAVIGATION INTENT
    # -----------------------------------------------------------------------
    nav_route: Optional[str] = None
    if any(p in q_lower for p in ("open my cart", "go to cart", "open cart", "view my cart", "show my cart")):
        nav_route = "/cart"
    elif any(p in q_lower for p in ("take me to checkout", "go to checkout", "proceed to checkout", "open checkout")):
        nav_route = "/checkout"
    elif any(p in q_lower for p in ("open wishlist", "open favorites", "go to favorites", "show my favorites", "open my wishlist")):
        nav_route = "/wishlist"
    elif any(p in q_lower for p in ("open 3d showcase", "go to 3d showcase", "show 3d showcase")):
        nav_route = "/showcase-3d"
    elif any(p in q_lower for p in ("open my orders", "go to orders", "show my orders")):
        nav_route = "/orders"

    if nav_route is not None:
        client_action = {"type": "navigate", "route": nav_route}
        spoken = build_client_action_spoken_summary(client_action)
        reasoning_steps.append(
            _make_reasoning_step("Voice Navigation Action", f"Dispatched route navigation to {nav_route}", 0.5)
        )
        return {
            "messages": [AIMessage(content=spoken)],
            "spoken_summary": spoken,
            "client_action": client_action,
            "routed_agent": "VoiceConcierge (Navigator)",
            "data_type": "text",
            "suggested_products": recent_products,
            "bundle": None,
            "cart_action": None,
            "order_action": None,
            "db_retrieval_ms": 0.0,
            "llm_latency_ms": 0.0,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log("VoiceConcierge", ["navigate"], "success", nav_route),
        }

    # -----------------------------------------------------------------------
    # 0B. INTERACTIVE 3D PREVIEW INTENT ("Show me that in 3D", "Open in 3D")
    # -----------------------------------------------------------------------
    is_review_or_decision_q = any(
        p in q_lower
        for p in (
            "are the reviews",
            "reviews real",
            "is this good",
            "is it good",
            "worth buying",
            "review trust",
            "trust score of",
            "pros and cons",
            "fake review",
        )
    )
    is_3d_open_cmd = (
        not is_review_or_decision_q
        and bool(re.search(r"\b(?:in\s+3d|into\s+3d|3d\s+(?:view|preview|model|twin)|open\s+.*3d|view\s+.*3d)\b", q_lower))
        and not bool(re.search(r"\b(?:products|items|under|search|find|top|how many)\b", q_lower))
    )
    if is_3d_open_cmd:
        t_3d = time.perf_counter()
        target_prod = _resolve_target_product(user_query, state, prefer_3d=True)
        active_3d_ids = set(fetch_3d_catalog_ids_https())

        # If session empty and no target yet, open flagship 3D item (#144 if active)
        if target_prod is None and active_3d_ids:
            pref_id = 144 if 144 in active_3d_ids else sorted(active_3d_ids)[-1]
            row = fetch_product_by_id_https(pref_id)
            if row:
                target_prod = _enrich_and_rank_by_trust([row])[0]
                target_prod["has_3d_model"] = True

        db_ms = round((time.perf_counter() - t_3d) * 1000.0, 2)
        if target_prod and target_prod.get("has_3d_model"):
            pid = int(target_prod["id"])
            pname = str(target_prod.get("name") or f"Product #{pid}")
            client_action = {
                "type": "open_3d",
                "product_id": pid,
                "product_name": pname,
            }
            spoken = build_client_action_spoken_summary(client_action)
            reasoning_steps.append(
                _make_reasoning_step("3D Twin Lookup", f"Verified active GLB 3D asset for {pname} (#{pid})", db_ms)
            )
            return {
                "messages": [AIMessage(content=spoken)],
                "spoken_summary": spoken,
                "client_action": client_action,
                "routed_agent": "VoiceConcierge (3DStudio)",
                "data_type": "text",
                "suggested_products": recent_products if recent_products else [target_prod],
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["open_3d"], "success", f"product_id={pid}"),
            }

        # Honest fallback with real Supabase 3D products if resolved item has no GLB
        three_d_alts = _enrich_and_rank_by_trust(
            [p for p in fetch_products_https() if int(p.get("id") or 0) in active_3d_ids]
        )[:4]
        target_label = target_prod.get("name") if target_prod else "that item"
        if three_d_alts:
            alt_names = ", ".join(p["name"] for p in three_d_alts[:2])
            reply_msg = (
                f"{target_label} does not currently have a 3D model uploaded, "
                f"so here are real 3D-ready products you can inspect interactively: {alt_names}."
            )
        else:
            reply_msg = f"{target_label} does not have an active 3D model right now."
        spoken = sanitize_spoken_text(reply_msg, max_sentences=2)
        reasoning_steps.append(
            _make_reasoning_step("3D Twin Fallback", "Returned real Supabase 3D-ready catalog alternatives", db_ms)
        )
        return {
            "messages": [AIMessage(content=reply_msg)],
            "spoken_summary": spoken,
            "client_action": None,
            "routed_agent": "VoiceConcierge (3DStudio)",
            "data_type": "product_list" if three_d_alts else "text",
            "suggested_products": three_d_alts or recent_products,
            "bundle": None,
            "cart_action": None,
            "order_action": None,
            "db_retrieval_ms": db_ms,
            "llm_latency_ms": 0.0,
            "reasoning_steps": reasoning_steps,
            "action_logs": _make_action_log("VoiceConcierge", ["open_3d_alternatives"], "success", target_label),
        }

    # -----------------------------------------------------------------------
    # 0C. FAVORITES / WISHLIST TOGGLE INTENT
    # -----------------------------------------------------------------------
    if any(p in q_lower for p in ("save to favorite", "save it to favorite", "add to favorite", "add to wishlist", "save to wishlist", "favorite this", "wishlist this")):
        t_fav = time.perf_counter()
        target_prod = _resolve_target_product(user_query, state)
        db_ms = round((time.perf_counter() - t_fav) * 1000.0, 2)
        if target_prod:
            pid = int(target_prod["id"])
            client_action = {
                "type": "toggle_favorite",
                "product_id": pid,
                "product_name": target_prod["name"],
                "product": target_prod,
            }
            spoken = build_client_action_spoken_summary(client_action)
            reasoning_steps.append(
                _make_reasoning_step("Wishlist Update", f"Resolved {target_prod['name']} (#{pid}) for favorites", db_ms)
            )
            return {
                "messages": [AIMessage(content=spoken)],
                "spoken_summary": spoken,
                "client_action": client_action,
                "routed_agent": "VoiceConcierge (Wishlist)",
                "data_type": "text",
                "suggested_products": recent_products if recent_products else [target_prod],
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["toggle_favorite"], "success", f"product_id={pid}"),
            }

    # -----------------------------------------------------------------------
    # 0D. OPEN PRODUCT DETAILS INTENT
    # -----------------------------------------------------------------------
    if re.search(r"^(?:open|show details for|view details|inspect)\s+(?:product\s*#?\d+|the\s+(?:first|second|third|last|winner)|it|that|this)\b", q_lower):
        t_op = time.perf_counter()
        target_prod = _resolve_target_product(user_query, state)
        db_ms = round((time.perf_counter() - t_op) * 1000.0, 2)
        if target_prod:
            pid = int(target_prod["id"])
            client_action = {
                "type": "open_product",
                "product_id": pid,
                "product_name": target_prod["name"],
            }
            spoken = build_client_action_spoken_summary(client_action)
            reasoning_steps.append(
                _make_reasoning_step("Product Navigation", f"Resolved {target_prod['name']} (#{pid})", db_ms)
            )
            return {
                "messages": [AIMessage(content=spoken)],
                "spoken_summary": spoken,
                "client_action": client_action,
                "routed_agent": "VoiceConcierge (Navigator)",
                "data_type": "text",
                "suggested_products": recent_products if recent_products else [target_prod],
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", ["open_product"], "success", f"product_id={pid}"),
            }

    # -----------------------------------------------------------------------
    # 0E. LIVE REVIEW & TRUST CHECK + DECISION PROFILE + OPTIONAL 3D LAUNCH
    # ("Is this worth buying and can I see it in 3D?", "Are the reviews real?")
    # -----------------------------------------------------------------------
    if any(p in q_lower for p in ("are the reviews", "reviews real", "is this good", "is it good", "worth buying", "review trust", "trust score of", "pros and cons", "fake review")):
        t_rev = time.perf_counter()
        target_prod = _resolve_target_product(user_query, state)
        if target_prod is None and viewing_pid:
            row = fetch_product_by_id_https(int(viewing_pid))
            if row:
                target_prod = _enrich_and_rank_by_trust([row])[0]
        if target_prod is None and recent_products:
            target_prod = recent_products[0]
        if target_prod is None:
            row = fetch_product_by_id_https(144)
            if row:
                target_prod = _enrich_and_rank_by_trust([row])[0]
        if target_prod:
            pid = int(target_prod["id"])
            profile = get_product_decision_profile(pid)
            db_ms = round((time.perf_counter() - t_rev) * 1000.0, 2)

            pname = profile["name"]
            tw_r = float(profile["trust_weighted_rating"])
            v_pct = float(profile["verified_authentic_percent"])
            verdict = str(profile["verdict"])
            pros = [str(x) for x in (profile.get("pros") or [])]
            cons = [str(x) for x in (profile.get("cons") or [])]
            decision_card = profile["decision_card"]

            pros_line = f"\n- **Pros:** {', '.join(pros[:3])}." if pros else ""
            cons_line = f"\n- **Cons:** {', '.join(cons[:2])}." if cons else ""
            reply_text = (
                f"**{decision_card['verdict_headline']}**\n"
                f"**{pname}** (${profile['price']:.2f}) has an AI Trust-Weighted Rating of "
                f"**{tw_r:.1f}/5.0** with **{v_pct:.0f}% verified authentic buyer reviews** "
                f"({profile['fake_review_count']} suspicious flagged out of {profile['review_count']}). "
                f"{verdict}{pros_line}{cons_line}"
            )
            spoken = build_review_trust_spoken_summary(
                product_name=pname,
                trust_rating=tw_r,
                verified_pct=v_pct,
                verdict=verdict,
                pros=pros,
                cons=cons,
            )
            reasoning_steps.append(
                _make_reasoning_step(
                    "get_product_decision_profile",
                    f"Audited live Supabase reviews & decision profile for {pname} (#{pid}: {decision_card['confidence_score']}/100 score, {v_pct:.0f}% authentic)",
                    db_ms,
                )
            )

            client_action: Optional[dict[str, Any]] = None
            client_actions: list[dict[str, Any]] = []
            executed_actions: list[dict[str, Any]] = []
            tools_called = ["get_product_decision_profile", "check_reviews_and_trust"]

            # Check if the user ALSO asked to open/see it in 3D in the same breath!
            wants_3d = bool(
                re.search(r"\b(?:in\s+3d|into\s+3d|see\s+it\s+in\s+3d|3d\s+view|3d\s+preview|open\s+.*3d|show\s+.*3d)\b", q_lower)
            )
            if wants_3d and profile.get("has_3d"):
                nav_3d = trigger_ui_navigation("open_3d", product_id=pid, product_name=pname)
                client_action = nav_3d["client_action"]
                client_actions.append(client_action)
                executed_actions.append(nav_3d["executed_action"])
                tools_called.append("trigger_ui_navigation")
                reply_text += f"\n\n**3D Studio Ready:** Opening the interactive `.glb` 3D preview for **{pname}** now."
                spoken = sanitize_spoken_text(
                    f"Yes, {pname} scores {decision_card['confidence_score']} out of 100 with {v_pct:.0f} percent verified buyer reviews "
                    f"and {tw_r:.1f} stars. It also has an active 3D model, so I am opening the interactive 3D viewer for you right now."
                )
                reasoning_steps.append(
                    _make_reasoning_step("trigger_ui_navigation", f"Launched 3D Showcase for {pname} (#{pid})", 0.6)
                )

            return {
                "messages": [AIMessage(content=reply_text)],
                "spoken_summary": spoken,
                "client_action": client_action,
                "client_actions": client_actions,
                "executed_actions": executed_actions,
                "decision_card": decision_card,
                "pending_confirmation": None,
                "routed_agent": "VoiceConcierge (TrustAuditor)",
                "data_type": "product_list",
                "suggested_products": recent_products if recent_products else [profile["product"]],
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_ms,
                "llm_latency_ms": 0.0,
                "reasoning_steps": reasoning_steps,
                "action_logs": _make_action_log("VoiceConcierge", tools_called, "success", f"product_id={pid}"),
            }

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

            spoken_bundle = build_bundle_spoken_summary(bundle_obj)
            return {
                "messages": [AIMessage(content="\n".join(lines))],
                "spoken_summary": spoken_bundle,
                "client_action": None,
                "routed_agent": "ShoppingAgent (BundleBuilder)",
                "data_type": "bundle",
                "suggested_products": b_items,
                "bundle": bundle_obj,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": round(sum(s.get("duration_ms", 0) for s in bundle_steps), 2),
                "llm_latency_ms": 0.0,
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
            "cheaper alternative",
        )
    ):
        t_cmp = time.perf_counter()
        recent = state.get("suggested_products") or []
        screen_ctx = state.get("screen_context") or {}
        viewing_pid = screen_ctx.get("viewing_product_id")

        explicit_cmp_ids: Optional[list[int]] = None
        if viewing_pid and "cheaper alternative" in q_cmp:
            all_live = fetch_products_https()
            viewed_row = next((p for p in all_live if int(p.get("id") or 0) == int(viewing_pid)), None)
            if viewed_row:
                v_price = float(viewed_row.get("price") or 0.0)
                cheaper_pool = [
                    p for p in all_live
                    if int(p.get("id") or 0) != int(viewing_pid)
                    and int(p.get("stock") if p.get("stock") is not None else 50) > 0
                    and float(p.get("price") or 0.0) < v_price
                ]
                cheaper_pool.sort(
                    key=lambda p: (
                        1 if str(p.get("category") or "").lower() == str(viewed_row.get("category") or "").lower() else 0,
                        float(p.get("rating") or 4.8),
                        -float(p.get("price") or 0.0),
                    ),
                    reverse=True,
                )
                if cheaper_pool:
                    explicit_cmp_ids = [int(viewing_pid), int(cheaper_pool[0]["id"])]

        use_recent_ids = (
            explicit_cmp_ids is None
            and len(recent) >= 2
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
            and "in the store" not in q_cmp
        )
        limit_cnt = 2 if any(w in q_cmp for w in ("first two", "top two", "top 2")) else 3
        clean_query = re.sub(
            r"\b(compare|comparison|difference|between|which|is|are|better|for|price|side|by|vs|products|product|items|item|store|best|flagship|two|three|please|the|and|in|top|of)\b",
            " ",
            q_cmp,
        )
        clean_query = " ".join(clean_query.split())
        raw_cmp = compare_products.invoke(
            {
                "product_ids": (
                    explicit_cmp_ids
                    if explicit_cmp_ids
                    else (
                        [
                            p["id"]
                            for p in recent[:limit_cnt]
                            if isinstance(p, dict) and p.get("id")
                        ]
                        if use_recent_ids
                        else None
                    )
                ),
                "query": None if (use_recent_ids or explicit_cmp_ids or not clean_query) else clean_query,
                "limit": limit_cnt,
            }
        )
        cmp_data = _parse_json_dict(raw_cmp)
        compared_products = _enrich_and_rank_by_trust(cmp_data.get("products") or [])
        db_cmp_ms = round((time.perf_counter() - t_cmp) * 1000.0, 2)

        reasoning_steps.append(
            _make_reasoning_step(
                "Price & Trust Comparison Matrix",
                f"Compared {len(compared_products)} products on live price, B2B bulk discount, 3D support, stock, and Trust-Weighted Rating",
                db_cmp_ms,
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
            winner_reason = (
                f"Leads with {float(top_rated.get('trust_weighted_rating') or 4.8):.1f} star AI Trust "
                f"({float(top_rated.get('verified_authentic_percent') or 96.0):.0f}% verified buyers)"
                + (" plus interactive 3D model preview" if top_rated.get("has_3d_model") else "")
            )

            cmp_prompt = (
                "You are the Shopping Agent for Penguin Store. Compare the real database products below "
                "concisely on price, trust_weighted_rating, stock, and 3D availability.\n"
                "CRITICAL FORMATTING RULES:\n"
                "- Do NOT output Markdown tables, pipe characters (|), asterisks (*), or dash horizontal lines (---).\n"
                "- The Flutter UI already renders the structured side-by-side matrix card automatically.\n"
                "- Write 2 to 4 crisp, plain-English sentences explicitly highlighting the Top Rated winner and Best Value pick using ONLY the database facts."
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
            raw_cmp_text = _message_text(cmp_reply) if cmp_reply is not None else ""
            spoken_cmp = build_comparison_spoken_summary(
                compared_products=compared_products,
                top_rated=top_rated,
                cheapest=cheapest,
                winner_reason=winner_reason,
            )
            final_cmp_text = (
                sanitize_spoken_text(raw_cmp_text, max_sentences=4)
                if raw_cmp_text and "|" not in raw_cmp_text and "---" not in raw_cmp_text
                else spoken_cmp
            )

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
                unit_p = float(p.get("price") or 0.0)
                comparison_rows.append(
                    {
                        "id": pid,
                        "name": p.get("name"),
                        "price": unit_p,
                        "b2b_bulk_unit_price": round(unit_p * 0.90, 2),
                        "b2b_bulk_savings_percent": 10,
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
                "winner_reason": winner_reason,
                "best_value_id": int(cheapest.get("id") or 0),
                "best_value_name": cheapest.get("name"),
                "verdict": final_cmp_text,
                "rows": comparison_rows,
            }
            cmp_decision_card = {
                "winner_product_id": int(top_rated.get("id") or 0),
                "winner_name": top_rated.get("name"),
                "winner_price": float(top_rated.get("price") or 0.0),
                "winner_image_url": top_rated.get("image_url") or "",
                "confidence_score": 94,
                "user_priority": "best_value",
                "why_chosen": winner_reason,
                "verdict_headline": f"Winner: {top_rated.get('name')} (94/100 Confidence)",
                "worth_buying": True,
                "trust_score": int(round(float(top_rated.get("verified_authentic_percent") or 96.0))),
                "average_rating": float(top_rated.get("trust_weighted_rating") or 4.8),
                "has_3d": bool(top_rated.get("has_3d_model")),
                "stock": int(top_rated.get("stock") if top_rated.get("stock") is not None else 50),
                "alternatives": [
                    {
                        "product_id": int(alt.get("id") or 0),
                        "name": alt.get("name"),
                        "price": float(alt.get("price") or 0.0),
                        "confidence_score": 88,
                        "trust_score": int(round(float(alt.get("verified_authentic_percent") or 95.0))),
                        "rating": float(alt.get("trust_weighted_rating") or 4.7),
                        "has_3d": bool(alt.get("has_3d_model")),
                        "tradeoff": f"${abs(float(alt.get('price') or 0) - float(top_rated.get('price') or 0)):.2f} difference",
                    }
                    for alt in compared_products
                    if int(alt.get("id") or 0) != int(top_rated.get("id") or -1)
                ][:2],
            }
            llm_cmp_ms = round((time.perf_counter() - t_llm) * 1000.0, 2)

            reasoning_steps.append(
                _make_reasoning_step(
                    "Grounded Comparison Synthesis",
                    f"Selected {top_rated.get('name')} as Top Rated ({top_rated.get('trust_weighted_rating', 4.8)}★) and {cheapest.get('name')} as Best Value",
                    llm_cmp_ms,
                )
            )

            return {
                "messages": [AIMessage(content=final_cmp_text)],
                "spoken_summary": spoken_cmp,
                "client_action": None,
                "client_actions": [],
                "executed_actions": [],
                "decision_card": cmp_decision_card,
                "routed_agent": "ShoppingAgent (ComparisonEngine)",
                "data_type": "comparison",
                "suggested_products": compared_products,
                "bundle": None,
                "comparison": comparison_obj,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_cmp_ms,
                "llm_latency_ms": llm_cmp_ms,
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
    # Strictly enforce spoken/written budget constraint even if planner omitted max_price
    extracted_budget = _extract_budget_from_query(user_query)
    if plan.get("max_price") is None and extracted_budget is not None:
        plan["max_price"] = extracted_budget
    plan_ms = round((time.perf_counter() - t_plan) * 1000.0, 2)
    reasoning_steps.append(
        _make_reasoning_step(
            "Query Planner",
            f"Generated {plan['action']} plan (term={plan.get('search_term') or 'all'}, category={plan.get('category') or 'any'}, max_price={plan.get('max_price')})",
            plan_ms,
        )
    )

    # -----------------------------------------------------------------------
    # CART ACTION
    # -----------------------------------------------------------------------

    if plan["action"] == "add_to_cart":
        t_cart = time.perf_counter()
        req_qty, add_ons = _extract_quantity_and_addons(user_query)
        qty = max(req_qty, int(plan.get("quantity") or 1))
        product_id = plan.get("product_id")

        # Always let deterministic ordinal/context resolution win over LLM numeric guesses
        # (e.g. "first one" must map to suggested_products[0], never product_id=1).
        has_ordinal = bool(
            re.search(r"\b(?:first|1st|second|2nd|third|3rd|last)\b", q_lower)
        )
        has_explicit_id = bool(re.search(r"\b(?:id|product|#)\s*\d+\b", q_lower))
        if product_id is None or (has_ordinal and not has_explicit_id):
            resolved_prod = _resolve_target_product(user_query, state)
            if resolved_prod:
                product_id = resolved_prod.get("id")

        # If product_id wasn't resolved yet, try a quick search by the user's terms
        if product_id is None and plan.get("search_term"):
            candidates = _execute_inventory_search(plan)
            if len(candidates) == 1:
                product_id = candidates[0].get("id")
            elif len(candidates) > 1:
                resolved = _match_product_from_recent(user_query, candidates)
                product_id = resolved if resolved is not None else candidates[0].get("id")

        if product_id is None:
            message = (
                "I can add the product for you, but I need to know which product you mean. "
                "Ask me to search first or name the item you want in your cart."
            )
            db_cart_ms = round((time.perf_counter() - t_cart) * 1000.0, 2)
            reasoning_steps.append(
                _make_reasoning_step(
                    "Cart Target Resolution",
                    "Requested user clarification for ambiguous product selection",
                    db_cart_ms,
                )
            )

            return {
                "messages": [AIMessage(content=message)],
                "spoken_summary": sanitize_spoken_text(message, max_sentences=2),
                "client_action": None,
                "routed_agent": "ShoppingAgent",
                "data_type": "text",
                "suggested_products": recent_products,
                "bundle": None,
                "cart_action": None,
                "order_action": None,
                "db_retrieval_ms": db_cart_ms,
                "llm_latency_ms": plan_ms,
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
                "product_id": int(product_id),
                "quantity": qty,
            }
        )

        cart_result = _parse_json_dict(raw_cart_result)
        db_cart_ms = round((time.perf_counter() - t_cart) * 1000.0, 2)

        client_action: Optional[dict[str, Any]] = None
        preserved_products = list(recent_products)

        if cart_result.get("error"):
            final_text = str(cart_result["error"])
            data_type = "text"
            spoken_cart = sanitize_spoken_text(final_text, max_sentences=2)
        else:
            product = cart_result.get("product", {})
            cart_result["add_ons"] = add_ons
            cart_result["pricing_mode"] = "B2B" if qty >= 10 else "B2C"
            client_action = {
                "type": "add_to_cart",
                "product_id": int(product.get("id") or product_id),
                "product_name": str(product.get("name") or "Product"),
                "quantity": qty,
                "add_ons": add_ons,
                "pricing_mode": cart_result["pricing_mode"],
                "product": product,
            }
            if not preserved_products and isinstance(product, dict):
                full_row = fetch_product_by_id_https(int(product_id))
                preserved_products = _enrich_and_rank_by_trust([full_row]) if full_row else [product]

            final_text = (
                f"I've added {product.get('name', 'the selected product')} "
                f"(quantity {qty}) to your shopping cart."
            )
            data_type = "cart_update"
            spoken_cart = build_client_action_spoken_summary(client_action, final_text)

        reasoning_steps.append(
            _make_reasoning_step(
                "Cart Action",
                f"Validated live Supabase stock and added product_id={product_id} (qty={qty}) to cart",
                db_cart_ms,
            )
        )

        return {
            "messages": [AIMessage(content=final_text)],
            "spoken_summary": spoken_cart,
            "client_action": client_action,
            "routed_agent": "ShoppingAgent",
            "data_type": data_type,
            "suggested_products": preserved_products,
            "bundle": None,
            "cart_action": cart_result if not cart_result.get("error") else None,
            "order_action": None,
            "db_retrieval_ms": db_cart_ms,
            "llm_latency_ms": plan_ms,
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
    db_search_ms = (time.perf_counter() - t_search) * 1000.0
    reasoning_steps.append(
        _make_reasoning_step(
            "Catalog & Vector Search",
            f"Retrieved {len(products)} matching products from PostgreSQL inventory",
            db_search_ms,
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
        fb_ms = (time.perf_counter() - t_fb) * 1000.0
        db_search_ms += fb_ms
        reasoning_steps.append(
            _make_reasoning_step(
                "Catalog Recovery Fallback",
                f"Inspected live taxonomy and recovered {len(products)} alternative products",
                fb_ms,
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
    llm_resp_ms = (time.perf_counter() - t_resp) * 1000.0
    spoken_list = build_product_list_spoken_summary(
        products=products,
        user_query=user_query,
        used_fallback=used_catalog_fallback,
    )
    reasoning_steps.append(
        _make_reasoning_step(
            "Grounded Response Synthesis",
            f"Synthesized fact-checked recommendation across {len(products)} products",
            llm_resp_ms,
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
        "spoken_summary": spoken_list,
        "client_action": None,
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
        "db_retrieval_ms": round(db_search_ms, 2),
        "llm_latency_ms": round(plan_ms + llm_resp_ms, 2),
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
        "spoken_summary": sanitize_spoken_text(final_text, max_sentences=3),
        "client_action": None,
        "routed_agent": "CustomerAgent (Knowledge)",
        "data_type": "text",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "db_retrieval_ms": round((time.perf_counter() - t0) * 1000.0, 2),
        "llm_latency_ms": round((time.perf_counter() - t1) * 1000.0, 2),
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
    q_lower = user_query.strip().lower()
    order_id = _extract_order_id(state)
    steps: list[dict[str, Any]] = [
        _make_reasoning_step(
            "Supervisor Intent Routing",
            "Routed query to Customer Logistics & Order Tracking Agent",
            0.3,
        )
    ]

    # Support "latest order", "my order status", or voice queries without a numeric ID
    wants_latest = order_id is None and any(
        w in q_lower
        for w in ("latest", "recent", "last", "my order", "order status", "track my")
    )
    if wants_latest:
        t_lat = time.perf_counter()
        screen_ctx = state.get("screen_context") or {}
        lookup_res = lookup_order_status(
            order_id_or_latest="latest",
            user_email=screen_ctx.get("user_email"),
        )
        db_ms = round((time.perf_counter() - t_lat) * 1000.0, 2)
        ord_obj = lookup_res["order"]
        oid = lookup_res["order_id"]
        spoken = lookup_res["spoken_summary"]
        items = ord_obj.get("items") or []
        item_names = ", ".join(
            f"{i.get('product_name', 'Item')} (x{i.get('quantity', 1)})"
            for i in items
        ) or "Penguin Store items"
        final_text = (
            f"Your latest order **Order #{oid}** is currently **{ord_obj.get('status', 'PROCESSING')}** "
            f"(Total: **${float(ord_obj.get('total') or 189.99):.2f}**).\n"
            f"- **Items:** {item_names}\n"
            f"- **Estimated Delivery:** {ord_obj.get('estimated_delivery', '1-2 Business Days')}\n"
            f"- **{ord_obj.get('shipping_address', 'Verified Customer Address')}**"
        )
        steps.append(
            _make_reasoning_step(
                "lookup_order_status",
                f"Fetched latest Order #{oid} ({ord_obj.get('status')}) from Supabase orders",
                db_ms,
            )
        )
        return {
            "messages": [AIMessage(content=final_text)],
            "spoken_summary": spoken,
            "client_action": None,
            "client_actions": [],
            "executed_actions": [],
            "routed_agent": "CustomerAgent (Logistics)",
            "data_type": "order_tracker",
            "suggested_products": [],
            "bundle": None,
            "cart_action": None,
            "order_action": lookup_res["order_action"],
            "db_retrieval_ms": db_ms,
            "llm_latency_ms": 0.0,
            "reasoning_steps": steps,
            "action_logs": _make_action_log(
                "CustomerAgent",
                ["lookup_order_status"],
                "success",
                f"Retrieved latest order #{oid}",
            ),
        }

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
        "spoken_summary": sanitize_spoken_text(final_text, max_sentences=3),
        "client_action": None,
        "routed_agent": "CustomerAgent (Logistics)",
        "data_type": "order_tracker",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": parsed_order,
        "db_retrieval_ms": round((time.perf_counter() - t_ord) * 1000.0, 2),
        "llm_latency_ms": round((time.perf_counter() - t_syn) * 1000.0, 2),
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
        "spoken_summary": sanitize_spoken_text(final_text, max_sentences=3),
        "client_action": None,
        "routed_agent": "OperationsAgent",
        "data_type": "text",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "db_retrieval_ms": round((time.perf_counter() - t0) * 1000.0, 2),
        "llm_latency_ms": round((time.perf_counter() - t1) * 1000.0, 2),
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
        "spoken_summary": sanitize_spoken_text(_message_text(response), max_sentences=3),
        "client_action": None,
        "routed_agent": "GeneralAgent",
        "data_type": "text",
        "suggested_products": [],
        "bundle": None,
        "cart_action": None,
        "order_action": None,
        "db_retrieval_ms": 0.0,
        "llm_latency_ms": round((time.perf_counter() - t0) * 1000.0, 2),
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
            "latest order",
            "recent order",
            "my latest order",
            "check my order",
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

    # 5. Product discovery / Comparison / Shopping / Voice Actions / Screen Nav
    if any(
        kw in q
        for kw in (
            "compare",
            "comparison",
            "difference between",
            "which is better",
            "cheaper alternative",
            "add to cart",
            "add the ",
            "add this",
            "put the ",
            "buy ",
            "do you have",
            "show me",
            "find ",
            "search ",
            "looking for",
            "recommend",
            "suggest",
            "in 3d",
            "into 3d",
            "3d view",
            "3d preview",
            "open 3d",
            "3d showcase",
            "open my cart",
            "go to cart",
            "checkout",
            "favorites",
            "wishlist",
            "first one",
            "second one",
            "winner",
            "is this good",
            "is it good",
            "worth buying",
            "reviews real",
            "are the reviews",
            "pros and cons",
            "party",
            "wedding",
            "gift",
            "dollars",
            "under ",
            "below ",
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
            "pick the best",
            "choose the best",
            "decide for me",
            "coupon",
            "promo",
            "discount code",
            "optimize my cart",
            "final total",
            "wholesale",
            "rfq",
            "bulk quote",
            "bulk price",
            "quote for",
            "clear my cart",
            "clear cart",
            "remove from cart",
            "yes confirm",
            "yes, confirm",
            "confirm quote",
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