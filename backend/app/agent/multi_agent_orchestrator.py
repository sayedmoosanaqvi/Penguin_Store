import json
import logging
from typing import Annotated, Any, Optional, Sequence, TypedDict

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


logger = logging.getLogger("uvicorn.error")


# ===========================================================================
# SHARED CLOUD LLM
# ===========================================================================

llm = ChatGroq(
    model="openai/gpt-oss-20b",
    temperature=0,
    max_retries=1,
)


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


def _create_initial_shopping_plan(
    state: AgentState,
) -> dict[str, Any]:
    """
    Let the Shopping Planner translate natural language into one bounded
    database action.
    """

    user_query = _latest_user_text(
        state
    )

    conversation = (
        _conversation_excerpt(
            state
        )
    )

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
and its exact product ID is known from the conversation.

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

7. Never invent product IDs.

8. If unsure, choose a broad safe search rather than guessing taxonomy.

Return JSON only.
""".strip()

    response = llm.invoke(
        [
            {
                "role": "system",
                "content": planner_prompt,
            },
            {
                "role": "user",
                "content": (
                    f"Conversation:\n{conversation}\n\n"
                    f"Latest request:\n{user_query}"
                ),
            },
        ]
    )

    raw_plan = _parse_json_object(
        _message_text(
            response
        )
    )

    plan = _normalize_shopping_plan(
        raw_plan
    )

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
    )[:14000]

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

    response = llm.invoke(
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
        _parse_json_object(
            _message_text(
                response
            )
        )
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
        response = llm.invoke(
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
                f"I've prepared "
                f"{product.get('name', 'the selected product')} "
                f"(quantity {cart_result.get('quantity', 1)}) "
                "for the cart."
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
# KNOWLEDGE NODE
# ===========================================================================

def knowledge_agent(
    state: AgentState,
):
    result = knowledge_react_agent.invoke(
        {
            "messages": state["messages"],
        }
    )

    new_messages = _only_new_messages(
        state["messages"],
        result.get(
            "messages",
            [],
        ),
    )

    return {
        "messages": new_messages,
        "data_type": "text",
        "suggested_products": [],
        "cart_action": None,
    }


# ===========================================================================
# LOGISTICS NODE
# ===========================================================================

def logistics_agent(
    state: AgentState,
):
    result = logistics_react_agent.invoke(
        {
            "messages": state["messages"],
        }
    )

    new_messages = _only_new_messages(
        state["messages"],
        result.get(
            "messages",
            [],
        ),
    )

    return {
        "messages": new_messages,
        "data_type": "text",
        "suggested_products": [],
        "cart_action": None,
    }


# ===========================================================================
# GENERAL AGENT
# ===========================================================================

def general_agent(
    state: AgentState,
):
    response = llm.invoke(
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
            *list(
                state["messages"]
            ),
        ]
    )

    return {
        "messages": [
            response
        ],
        "data_type": "text",
        "suggested_products": [],
        "cart_action": None,
    }


# ===========================================================================
# SUPERVISOR AGENT
# ===========================================================================

def supervisor_node(
    state: AgentState,
):
    system_prompt = """
You are the Supervisor Agent for Penguin Store's multi-agent autonomous
e-commerce system.

Route the customer's latest request to exactly ONE specialist.

RetrievalAgent
- products
- inventory
- prices
- product recommendations
- shopping
- outfits
- gifts
- styles
- categories
- cart requests
- buying products
- occasion-based shopping

KnowledgeAgent
- return policy
- refunds
- warranties
- payment methods
- store rules
- fulfillment policies
- general shipping policies

LogisticsAgent
- a specific order
- order tracking
- shipment status
- delivery status
- questions involving a specific order ID

GeneralAgent
- hello / hi / hey
- thanks
- goodbye
- casual conversation
- questions about CTRL-X capabilities

Examples:

"Do you have shirts?" -> RetrievalAgent

"I need something for a party" -> RetrievalAgent

"Find black shoes under 5000" -> RetrievalAgent

"What is your return policy?" -> KnowledgeAgent

"How long is the refund window?" -> KnowledgeAgent

"Where is order 23?" -> LogisticsAgent

"Hey" -> GeneralAgent

Respond ONLY with one exact route name:

RetrievalAgent
KnowledgeAgent
LogisticsAgent
GeneralAgent
""".strip()

    response = llm.invoke(
        [
            {
                "role": "system",
                "content": system_prompt,
            },
            *list(
                state["messages"]
            ),
        ]
    )

    route = _message_text(
        response
    ).lower()

    if "retrievalagent" in route:
        next_agent = "RetrievalAgent"

    elif "knowledgeagent" in route:
        next_agent = "KnowledgeAgent"

    elif "logisticsagent" in route:
        next_agent = "LogisticsAgent"

    elif "generalagent" in route:
        next_agent = "GeneralAgent"

    else:
        # Safe conversational fallback.
        next_agent = "GeneralAgent"

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