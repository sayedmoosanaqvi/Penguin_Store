import logging
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from app.agent.graph import agent_app

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
        
        # Invoke the graph with local Ollama model
        logger.info("Executing Local Agent Graph...")
        result = agent_app.invoke(inputs, config=config)
        
        if not result or "messages" not in result or not result["messages"]:
            raise HTTPException(status_code=500, detail="Agent graph returned an empty response.")
            
        last_message = result["messages"][-1]
        content = getattr(last_message, 'content', str(last_message))
        
        # Handle local model tool calls safely
        if not content and hasattr(last_message, 'tool_calls') and last_message.tool_calls:
            tool_name = last_message.tool_calls[0].get('name', 'unknown_tool')
            tool_args = last_message.tool_calls[0].get('args', {})
            logger.warning(f"ACTION INTERRUPTED: Agent requested tool '{tool_name}' with args {tool_args}.")
            return {"status": "paused", "message": f"Agent is waiting for human approval to run {tool_name}."}
            
        logger.info(f"Agent Final Response: '{content}'")
        return {"status": "success", "response": content}
        
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