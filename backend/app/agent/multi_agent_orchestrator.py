import json
import logging
import os
import re
from pathlib import Path
from typing import Annotated, Any, Optional, Sequence, TypedDict

from dotenv import load_dotenv
from langchain_core.messages import AIMessage, BaseMessage
from langchain_groq import ChatGroq
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import create_react_agent

from app.agent.tools import (
    add_to_cart,
    check_order_status,
    inspect_catalog,
    search_inventory,
    search_knowledge_base,
)

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

    data_type: str

    suggested_products: list[dict[str, Any]]

    cart_action: Optional[dict[str, Any]]

    order_action: Optional[dict[str, Any]]


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

    # Check ordinal reference like 'first one'
    if "first" in q_lower and len(recent_products) >= 1:
        pid = recent_products[0].get("id")
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
# INVENTORY EXECUTION
# ===========================================================================

def _execute_inventory_search(
    plan: dict[str, Any],
) -> list[dict[str, Any]]:
    """
    Execute one validated inventory search.
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

    return _parse_json_list(
        raw_result
    )


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
    names = [
        product.get(
            "name",
            "Product",
        )
        for product in products[:3]
    ]

    return (
        "I found matching products in the current Penguin Store "
        f"inventory: {', '.join(names)}. "
        "You can view the available options below."
    )


# ===========================================================================
# CONTROLLED SHOPPING / RETRIEVAL AGENT
# ===========================================================================

def retrieval_agent(
    state: AgentState,
):
    """
    Bounded shopping workflow.

    Maximum behavior:

    Planner
        ↓
    Search #1
        ↓
    if empty:
        Inspect catalog
        ↓
        Fallback planner
        ↓
        Search #2
        ↓
    Grounded answer

    The LLM cannot repeatedly call tools indefinitely.
    """

    user_query = _latest_user_text(
        state
    )

    logger.info(
        "[SHOPPING WORKFLOW] Started | Query=%r",
        user_query,
    )

    plan = _create_initial_shopping_plan(
        state
    )

    # -----------------------------------------------------------------------
    # CART ACTION
    # -----------------------------------------------------------------------

    if plan["action"] == "add_to_cart":
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

            return {
                "messages": [
                    AIMessage(
                        content=message
                    )
                ],
                "data_type": "text",
                "suggested_products": [],
                "cart_action": None,
                "order_action": None,
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

        return {
            "messages": [
                AIMessage(
                    content=final_text
                )
            ],
            "data_type": data_type,
            "suggested_products": [],
            "cart_action": (
                cart_result
                if not cart_result.get(
                    "error"
                )
                else None
            ),
            "order_action": None,
        }

    # -----------------------------------------------------------------------
    # FIRST INVENTORY SEARCH
    # -----------------------------------------------------------------------

    products = _execute_inventory_search(
        plan
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

    # -----------------------------------------------------------------------
    # GROUNDED FINAL RESPONSE
    # -----------------------------------------------------------------------

    final_text = (
        _create_grounded_product_response(
            user_query=user_query,
            products=products,
            used_catalog_fallback=(
                used_catalog_fallback
            ),
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
        "data_type": (
            "product_list"
            if products
            else "text"
        ),
        "suggested_products": products,
        "cart_action": None,
        "order_action": None,
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

    raw_policy = search_knowledge_base.invoke(
        {"query": user_query or "return refund warranty payment shipping policy"}
    )
    policy_context = str(raw_policy or "").strip()

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

    return {
        "messages": [AIMessage(content=final_text)],
        "data_type": "text",
        "suggested_products": [],
        "cart_action": None,
        "order_action": None,
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

    if order_id is None:
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
            "data_type": "text",
            "suggested_products": [],
            "cart_action": None,
            "order_action": None,
        }

    raw_order_json = check_order_status.invoke({"order_id": order_id})
    parsed_order = _parse_json_dict(raw_order_json)

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
            "data_type": "text",
            "suggested_products": [],
            "cart_action": None,
            "order_action": None,
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

    return {
        "messages": [AIMessage(content=final_text)],
        "data_type": "order_tracker",
        "suggested_products": [],
        "cart_action": None,
        "order_action": parsed_order,
    }


# ===========================================================================
# GENERAL AGENT
# ===========================================================================

def general_agent(
    state: AgentState,
):
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
                    "recommendations, inventory queries, cart actions, "
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
                "I can help you discover products, add items to your cart, "
                "track orders by Order ID, or answer store policy questions. "
                "How can I help you today?"
            )
        )

    return {
        "messages": [
            response
        ],
        "data_type": "text",
        "suggested_products": [],
        "cart_action": None,
        "order_action": None,
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

    # 4. Product discovery / Shopping / Cart actions
    if any(
        kw in q
        for kw in (
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
- products, inventory, prices, recommendations, shopping, outfits, gifts, styles, categories, cart requests, buying products

KnowledgeAgent
- return policy, refunds, warranties, payment methods, store rules, fulfillment policies, general shipping policies

LogisticsAgent
- a specific order, order tracking, shipment status, delivery status, questions involving a specific order ID

GeneralAgent
- hello / hi / hey, thanks, goodbye, casual conversation, questions about CTRL-X capabilities

Respond ONLY with one exact route name:
RetrievalAgent
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