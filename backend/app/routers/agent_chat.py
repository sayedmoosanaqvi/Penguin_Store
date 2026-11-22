import json
import logging
import time
from collections import deque
from datetime import datetime, timezone
from functools import partial
from threading import Lock
from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from langchain_core.messages import AIMessage
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from app.agent.multi_agent_orchestrator import (
    multi_agent_app as agent_app,
)
from app.agent.voice_formatter import sanitize_spoken_text
from app.services.audit_service import (
    fetch_ctrlx_audit_logs,
    record_ctrlx_audit,
)
from app.services.ai_telemetry_service import (
    record_ctrlx_metric,
    record_voice_concierge_metric,
)


def append_audit_log(entry: dict[str, Any]) -> None:
    record_ctrlx_audit(entry)


def get_audit_logs(limit: int = 50) -> list[dict[str, Any]]:
    return fetch_ctrlx_audit_logs(limit=limit)


# ===========================================================================
# LOGGING
# ===========================================================================

logger = logging.getLogger("uvicorn.error")


# ===========================================================================
# ROUTER
# ===========================================================================

router = APIRouter(
    tags=["AI Agent"],
)


# ===========================================================================
# REQUEST MODELS
# ===========================================================================

class ChatRequest(BaseModel):
    user_input: str = Field(
        ...,
        min_length=1,
        max_length=2000,
    )

    thread_id: str = Field(
        ...,
        min_length=1,
        max_length=200,
    )

    current_route: Optional[str] = Field(default=None, max_length=200)
    viewing_product_id: Optional[int] = Field(default=None)
    selected_variant: Optional[str] = Field(default=None, max_length=100)
    visible_product_ids: Optional[list[int]] = Field(default=None)
    cart_item_count: Optional[int] = Field(default=None)
    cart_total: Optional[float] = Field(default=None)
    cart_items: Optional[list[dict[str, Any]]] = Field(default=None)
    user_email: Optional[str] = Field(default=None, max_length=200)
    pending_confirmation: Optional[dict[str, Any]] = Field(default=None)
    confirm_pending_action: bool = Field(default=False)
    is_voice: bool = Field(default=False)
    stt_latency_ms: Optional[float] = Field(default=None)
    voice_transcript: Optional[str] = Field(default=None, max_length=2000)


class ApproveRequest(BaseModel):
    thread_id: str = Field(
        ...,
        min_length=1,
        max_length=200,
    )


# ===========================================================================
# INTERNAL HELPERS
# ===========================================================================

def _parse_tool_json(
    content: Any,
) -> Any:
    """
    Safely parse JSON returned by an agent tool.
    """

    if isinstance(
        content,
        (dict, list),
    ):
        return content

    if not isinstance(
        content,
        str,
    ):
        return None

    try:
        return json.loads(
            content
        )

    except json.JSONDecodeError:
        return None


def _extract_ai_text(
    message: Any,
) -> str:
    """
    Extract normal text from the final AI message.

    Handles both ordinary string content and structured content blocks.
    """

    if not isinstance(
        message,
        AIMessage,
    ):
        return ""

    content = message.content

    if isinstance(
        content,
        str,
    ):
        return content.strip()

    if isinstance(
        content,
        list,
    ):
        text_parts = []

        for part in content:
            if isinstance(
                part,
                str,
            ):
                text_parts.append(
                    part
                )

            elif isinstance(
                part,
                dict,
            ):
                text = part.get(
                    "text"
                )

                if text:
                    text_parts.append(
                        str(text)
                    )

        return "\n".join(
            text_parts
        ).strip()

    return str(
        content
    ).strip()


def _extract_agent_payload(
    result: dict,
) -> dict:
    """
    Convert LangGraph state into the stable JSON contract used by Flutter.

    Newer graph nodes may return structured state directly.

    For backward compatibility, this also scans ToolMessages generated
    by the current ReAct agents.
    """

    messages = result.get(
        "messages",
        [],
    )

    final_text = ""

    if messages:
        final_text = _extract_ai_text(
            messages[-1]
        )

    # -----------------------------------------------------------------------
    # Prefer structured graph state.
    #
    # This prepares the API for the next architecture where specialist
    # agents return structured artifacts directly instead of forcing the
    # API router to infer everything from message history.
    # -----------------------------------------------------------------------

    suggested_products = result.get(
        "suggested_products",
        [],
    )

    if not isinstance(
        suggested_products,
        list,
    ):
        suggested_products = []

    cart_action = result.get(
        "cart_action"
    )

    order_action = result.get(
        "order_action"
    )

    data_type = result.get(
        "data_type",
        "text",
    )

    # -----------------------------------------------------------------------
    # Backward-compatible ToolMessage extraction.
    # -----------------------------------------------------------------------

    if messages:
        successful_product_result = None
        saw_product_search = False

        for message in reversed(
            messages
        ):
            if getattr(
                message,
                "type",
                "",
            ) != "tool":
                continue

            tool_name = getattr(
                message,
                "name",
                "",
            )

            parsed = _parse_tool_json(
                getattr(
                    message,
                    "content",
                    None,
                )
            )

            # ---------------------------------------------------------------
            # Cart action
            # ---------------------------------------------------------------

            if (
                tool_name == "add_to_cart"
                and isinstance(parsed, dict)
            ):
                if cart_action is None:
                    cart_action = parsed

                if data_type == "text":
                    data_type = "cart_update"

                continue

            # ---------------------------------------------------------------
            # Order status action
            # ---------------------------------------------------------------

            if (
                tool_name == "check_order_status"
                and isinstance(parsed, dict)
                and "order" in parsed
            ):
                if order_action is None:
                    order_action = parsed

                if data_type == "text":
                    data_type = "order_tracker"

                continue

            # ---------------------------------------------------------------
            # Product search
            #
            # IMPORTANT:
            # We preserve the newest NON-EMPTY successful result.
            #
            # A ReAct agent may perform:
            #
            # search -> []
            # search -> []
            # search -> [products]
            # search -> []
            #
            # The old router could accidentally expose the last empty list.
            # ---------------------------------------------------------------

            if (
                tool_name == "search_inventory"
                and isinstance(parsed, list)
            ):
                saw_product_search = True

                if (
                    parsed
                    and successful_product_result is None
                ):
                    successful_product_result = parsed

        if (
            not suggested_products
            and successful_product_result is not None
        ):
            suggested_products = (
                successful_product_result
            )

        if (
            suggested_products
            or saw_product_search
        ):
            if data_type == "text":
                data_type = "product_list"

    action_logs = result.get("action_logs")
    if not isinstance(action_logs, list):
        action_logs = []

    reasoning_steps = result.get("reasoning_steps")
    if not isinstance(reasoning_steps, list):
        reasoning_steps = []

    bundle = result.get("bundle") if data_type == "bundle" else None
    if not isinstance(bundle, dict):
        bundle = None

    comparison = result.get("comparison") if isinstance(result.get("comparison"), dict) else None

    decision_card = result.get("decision_card")
    if not isinstance(decision_card, dict):
        decision_card = None

    pending_confirmation = result.get("pending_confirmation")
    if not isinstance(pending_confirmation, dict):
        pending_confirmation = None

    client_action = result.get("client_action")
    if not isinstance(client_action, dict):
        client_action = None

    client_actions = result.get("client_actions")
    if not isinstance(client_actions, list):
        client_actions = [client_action] if client_action else []

    executed_actions = result.get("executed_actions")
    if not isinstance(executed_actions, list):
        executed_actions = []
    if not executed_actions and client_action:
        executed_actions = [
            {
                "action_id": f"act_{int(time.time() * 1000)}",
                "type": client_action.get("type"),
                "product_id": client_action.get("product_id"),
                "product_name": client_action.get("product_name"),
                "label": f"Executed {client_action.get('type')}",
                "can_undo": client_action.get("type") in {"add_to_cart", "toggle_favorite", "apply_promo"},
                "undo_action": (
                    {
                        "type": "remove_from_cart",
                        "product_id": client_action.get("product_id"),
                        "product_name": client_action.get("product_name"),
                        "quantity": client_action.get("quantity") or 1,
                    }
                    if client_action.get("type") == "add_to_cart"
                    else (
                        {"type": "clear_promo"}
                        if client_action.get("type") == "apply_promo"
                        else (
                            {
                                "type": "toggle_favorite",
                                "product_id": client_action.get("product_id"),
                                "product_name": client_action.get("product_name"),
                            }
                            if client_action.get("type") == "toggle_favorite"
                            else None
                        )
                    )
                ),
            }
        ]

    raw_spoken = result.get("spoken_summary") or final_text
    spoken_summary = sanitize_spoken_text(raw_spoken, max_sentences=4)
    if not spoken_summary:
        spoken_summary = sanitize_spoken_text(final_text, max_sentences=3)

    routed_agent = result.get("routed_agent") or result.get("next_agent") or "CTRL-X"

    products_normalized = [
        {
            "id": p.get("id"),
            "name": p.get("name"),
            "price": float(p.get("price") or 0.0),
            "original_price": p.get("original_price"),
            "image_url": p.get("image_url") or "",
            "stock": p.get("stock", 50),
            "has_3d": bool(p.get("has_3d_model") or p.get("has_3d")),
            "has_3d_model": bool(p.get("has_3d_model") or p.get("has_3d")),
            "trust_score": p.get("trust_weighted_rating") or p.get("rating") or 4.8,
            "trust_weighted_rating": p.get("trust_weighted_rating") or p.get("rating") or 4.8,
            "verified_authentic_percent": p.get("verified_authentic_percent", 96.0),
            "decision_score": p.get("decision_score"),
            "category": p.get("category") or "CATALOG",
            "description": p.get("description") or "",
        }
        for p in suggested_products
        if isinstance(p, dict)
    ]

    db_retrieval_ms = float(result.get("db_retrieval_ms") or 0.0)
    llm_latency_ms = float(result.get("llm_latency_ms") or 0.0)

    return {
        "status": "success",
        "response": final_text,
        "reply": final_text,
        "spoken_summary": spoken_summary,
        "data_type": data_type,
        "suggested_products": products_normalized,
        "products": products_normalized,
        "bundle": bundle,
        "comparison": comparison,
        "decision_card": decision_card,
        "pending_confirmation": pending_confirmation,
        "cart_action": cart_action,
        "order_action": order_action,
        "client_action": client_action,
        "client_actions": client_actions,
        "executed_actions": executed_actions,
        "routed_agent": routed_agent,
        "reasoning_steps": reasoning_steps,
        "reasoning_trace": reasoning_steps,
        "action_logs": action_logs,
        "db_retrieval_ms": db_retrieval_ms,
        "llm_latency_ms": llm_latency_ms,
    }


# ===========================================================================
# CHAT ENDPOINT
# ===========================================================================

@router.post(
    "/api/agent/chat"
)
async def chat_with_agent(
    request: ChatRequest,
):
    logger.info(
        "--- AGENT SESSION | Thread ID: %s ---",
        request.thread_id,
    )

    # Avoid dumping arbitrarily large user messages into production logs.
    logger.info(
        "User Input: %r",
        request.user_input[:300],
    )

    try:
        screen_context = {
            "current_route": request.current_route,
            "viewing_product_id": request.viewing_product_id,
            "selected_variant": request.selected_variant,
            "visible_product_ids": request.visible_product_ids,
            "cart_item_count": request.cart_item_count,
            "cart_total": request.cart_total,
            "cart_items": request.cart_items,
            "user_email": request.user_email,
            "pending_confirmation": request.pending_confirmation,
            "confirm_pending_action": request.confirm_pending_action,
        }
        inputs = {
            "messages": [
                (
                    "user",
                    request.user_input,
                )
            ],
            "screen_context": screen_context,
            "client_action": None,
            "client_actions": None,
            "executed_actions": None,
            "decision_card": None,
            " spoken_summary": None,
            "spoken_summary": None,
        }

        config = {
            "configurable": {
                "thread_id": (
                    request.thread_id
                )
            }
        }

        logger.info(
            "Executing Agent Graph..."
        )

        # ---------------------------------------------------------------
        # LangGraph/Groq calls are synchronous in the current architecture.
        #
        # Run them in FastAPI's thread pool so a slow LLM/database request
        # does not block the server's async event loop.
        # ---------------------------------------------------------------

        started_at = time.perf_counter()

        invoke_agent = partial(
            agent_app.invoke,
            inputs,
            config=config,
        )

        result = await run_in_threadpool(
            invoke_agent
        )

        if (
            not result
            or not isinstance(
                result,
                dict,
            )
        ):
            raise RuntimeError(
                "Agent graph returned an invalid result."
            )

        if (
            "messages" not in result
            or not result["messages"]
        ):
            raise RuntimeError(
                "Agent graph returned no messages."
            )

        payload = _extract_agent_payload(
            result
        )
        latency_ms = round((time.perf_counter() - started_at) * 1000.0, 2)
        payload["latency_ms"] = latency_ms

        tools_called = [
            t
            for entry in payload.get("action_logs", [])
            for t in entry.get("tools", [])
        ]

        append_audit_log(
            {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "thread_id": request.thread_id,
                "user_input": request.user_input[:200],
                "voice_transcript": request.voice_transcript,
                "routed_agent": payload["routed_agent"],
                "tools_called": tools_called,
                "data_type": payload["data_type"],
                "latency_ms": latency_ms,
                "status": "success",
            }
        )
        try:
            record_ctrlx_metric(
                latency_ms=latency_ms,
                tool_calls_count=len(tools_called),
                success=True,
                routed_agent=payload["routed_agent"],
                data_type=payload["data_type"],
            )
            if request.is_voice or payload.get("client_action") or payload.get("decision_card"):
                record_voice_concierge_metric(
                    stt_latency_ms=request.stt_latency_ms,
                    db_retrieval_ms=payload.get("db_retrieval_ms"),
                    llm_latency_ms=payload.get("llm_latency_ms"),
                    total_latency_ms=latency_ms,
                    action_executed=(
                        (payload.get("client_action") or {}).get("type")
                        if isinstance(payload.get("client_action"), dict)
                        else payload["data_type"]
                    ),
                    tools_called=tools_called,
                    decision_made=bool(payload.get("decision_card")),
                    success=True,
                    routed_agent=payload["routed_agent"],
                )
        except Exception:
            pass

        logger.info(
            "Agent completed | "
            "Routed: %s | Data Type: %s | "
            "Suggested Products: %s | Latency: %sms",
            payload["routed_agent"],
            payload["data_type"],
            len(
                payload[
                    "suggested_products"
                ]
            ),
            latency_ms,
        )

        return payload

    except HTTPException:
        raise

    except Exception:
        logger.exception(
            "AGENT EXECUTION FAILED"
        )
        append_audit_log(
            {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "thread_id": request.thread_id,
                "user_input": request.user_input[:200],
                "routed_agent": "CTRL-X",
                "tools_called": [],
                "data_type": "error",
                "latency_ms": 0.0,
                "status": "error",
            }
        )

        # Do not expose internal stack traces, database details,
        # environment variables, or provider errors to the client.
        raise HTTPException(
            status_code=500,
            detail=(
                "CTRL-X could not complete the request."
            ),
        )


# ===========================================================================
# APPROVAL ENDPOINT
# ===========================================================================

@router.post(
    "/api/agent/approve"
)
async def approve_agent_action(
    request: ApproveRequest,
):
    logger.info(
        "--- AGENT APPROVAL | Thread ID: %s ---",
        request.thread_id,
    )

    try:
        config = {
            "configurable": {
                "thread_id": (
                    request.thread_id
                )
            }
        }

        logger.info(
            "Resuming Agent Graph..."
        )

        resume_agent = partial(
            agent_app.invoke,
            None,
            config=config,
        )

        result = await run_in_threadpool(
            resume_agent
        )

        if (
            not result
            or not result.get(
                "messages"
            )
        ):
            raise RuntimeError(
                "Agent graph returned no response "
                "after approval."
            )

        payload = _extract_agent_payload(
            result
        )

        return payload

    except HTTPException:
        raise

    except Exception:
        logger.exception(
            "AGENT APPROVAL EXECUTION FAILED"
        )

        raise HTTPException(
            status_code=500,
            detail=(
                "CTRL-X could not complete "
                "the approved action."
            ),
        )