import json
import logging
from functools import partial
from typing import Any

from fastapi import APIRouter, HTTPException
from langchain_core.messages import AIMessage
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from app.agent.multi_agent_orchestrator import (
    multi_agent_app as agent_app,
    
)


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

    return {
        "status": "success",
        "response": final_text,
        "data_type": data_type,
        "suggested_products": suggested_products,
        "cart_action": cart_action,
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
        inputs = {
            "messages": [
                (
                    "user",
                    request.user_input,
                )
            ]
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

        logger.info(
            "Agent completed | "
            "Data Type: %s | "
            "Suggested Products: %s",
            payload["data_type"],
            len(
                payload[
                    "suggested_products"
                ]
            ),
        )

        return payload

    except HTTPException:
        raise

    except Exception:
        logger.exception(
            "AGENT EXECUTION FAILED"
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