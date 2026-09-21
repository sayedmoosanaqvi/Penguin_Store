import json
import logging
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from langchain_core.messages import ToolMessage, AIMessage


from app.agent.multi_agent_orchestrator import multi_agent_app as agent_app

# 1. Configure Enterprise-Grade Logging
logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("PenguinStore-Agent")

router = APIRouter(tags=["AI Agent"])

class ChatRequest(BaseModel):
    user_input: str
    thread_id: str

class ApproveRequest(BaseModel):
    thread_id: str

@router.post("/api/agent/chat")
async def chat_with_agent(request: ChatRequest):
    logger.info(f"--- NEW SESSION INITIATED | Thread ID: {request.thread_id} ---")
    logger.info(f"User Input: '{request.user_input}'")
    
    try:
        inputs = {"messages": [("user", request.user_input)]}
        config = {"configurable": {"thread_id": request.thread_id}}
        
        # Invoke the graph with your model
        logger.info("Executing Agent Graph...")
        result = agent_app.invoke(inputs, config=config)
        
        if not result or "messages" not in result or not result["messages"]:
            raise HTTPException(status_code=500, detail="Agent graph returned an empty response.")
            
        messages = result["messages"]
        final_text = ""
        suggested_products = []
        cart_action = None
        data_type = "text"
        
        # 1. Extract the final conversational response
        last_message = messages[-1]
        if isinstance(last_message, AIMessage):
            final_text = getattr(last_message, 'content', str(last_message))

            # Handle edge case: LLM wants human approval for a local tool call
            if not final_text and hasattr(last_message, 'tool_calls') and last_message.tool_calls:
                tool_name = last_message.tool_calls[0].get('name', 'unknown_tool')
                tool_args = last_message.tool_calls[0].get('args', {})
                logger.warning(f"ACTION INTERRUPTED: Agent requested tool '{tool_name}' with args {tool_args}.")
                return {"status": "paused", "message": f"Agent is waiting for human approval to run {tool_name}."}

        # 2. Scan backwards for the most recent database tool call
        for msg in reversed(messages):
            if getattr(msg, 'type', '') == 'tool':
                try:
                    content = getattr(msg, 'content', '[]')
                    parsed = json.loads(content)
                    tool_name = getattr(msg, 'name', '')

                    if tool_name == 'add_to_cart':
                        cart_action = parsed
                        data_type = "cart_update"
                        break
                    elif tool_name == 'search_inventory':
                        suggested_products = parsed
                        data_type = "product_list"
                        break
                except json.JSONDecodeError:
                    logger.error("Failed to parse tool output as JSON.")

        logger.info(f"Agent Final Response: '{final_text}' | Data Type: '{data_type}'")
        
        # 3. Return a multi-modal JSON payload to Flutter
        return {
            "status": "success", 
            "response": final_text,
            "data_type": data_type,
            "suggested_products": suggested_products,
            "cart_action": cart_action
        }
        
    except Exception as e:
        logger.error(f"AGENT CRASHED: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@router.post("/api/agent/approve")
async def approve_agent_action(request: ApproveRequest):
    logger.info(f"--- ACTION APPROVED | Thread ID: {request.thread_id} ---")
    try:
        config = {"configurable": {"thread_id": request.thread_id}}
        
        logger.info("Resuming Agent Graph from interruption point...")
        result = agent_app.invoke(None, config=config)
        
        last_message = result["messages"][-1]
        content = getattr(last_message, 'content', str(last_message))
        logger.info(f"Agent Post-Approval Response: '{content}'")
        
        return {"status": "success", "response": content}
        
    except Exception as e:
        logger.error(f"APPROVAL EXECUTION FAILED: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))