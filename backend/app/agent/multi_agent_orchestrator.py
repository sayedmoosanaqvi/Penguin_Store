from langgraph.checkpoint.memory import MemorySaver
from typing import Annotated, Sequence, TypedDict, Literal
from langchain_core.messages import BaseMessage
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_groq import ChatGroq
from langgraph.prebuilt import create_react_agent
from pydantic import BaseModel, Field

# Restore your actual e-commerce tools here!
from app.agent.rag import search_inventory, add_to_cart, check_order_status

llm = ChatGroq(
    model="openai/gpt-oss-20b", 
    max_retries=1
)

class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    next_agent: str

class Route(BaseModel):
    next_agent: Literal["RetrievalAgent", "LogisticsAgent"] = Field(
        description="The next agent to route to."
    )

def retrieval_agent(state: AgentState):
    agent = create_react_agent(
        llm, 
        tools=[search_inventory, add_to_cart], 
        state_modifier=(
            "You are the official AI assistant for Penguin Store. "
            "You MUST use the 'search_inventory' tool to fetch and show products when the user asks for items like shirts or phones. "
            "You MUST use the 'add_to_cart' tool when they ask to buy or add an item to their cart. "
            "Never say you do not have a store."
        )
    ) 
    result = agent.invoke({"messages": state["messages"]})
    return {"messages": result["messages"]}

def logistics_agent(state: AgentState):
    agent = create_react_agent(
        llm, 
        tools=[check_order_status],
        state_modifier="You are a logistics assistant for Penguin Store. Assist users with order tracking."
    ) 
    result = agent.invoke({"messages": state["messages"]})
    return {"messages": result["messages"]}

def supervisor_node(state: AgentState):
    system_prompt = (
        "You are the routing supervisor for an e-commerce AI system.\n"
        "1. If the user asks about finding products, shopping, or adding to cart, route to 'RetrievalAgent'.\n"
        "2. If the user asks about order tracking or shipments, route to 'LogisticsAgent'."
    )
    
    router = llm.with_structured_output(Route)
    response = router.invoke([{"role": "system", "content": system_prompt}] + list(state["messages"]))
    
    return {"next_agent": response.next_agent}

workflow = StateGraph(AgentState)
workflow.add_node("Supervisor", supervisor_node)
workflow.add_node("RetrievalAgent", retrieval_agent)
workflow.add_node("LogisticsAgent", logistics_agent)

workflow.set_entry_point("Supervisor")

workflow.add_conditional_edges(
    "Supervisor",
    lambda state: state["next_agent"],
    {
        "RetrievalAgent": "RetrievalAgent",
        "LogisticsAgent": "LogisticsAgent"
    }
)

workflow.add_edge("RetrievalAgent", END)
workflow.add_edge("LogisticsAgent", END)

checkpointer = MemorySaver()
multi_agent_app = workflow.compile(checkpointer=checkpointer)