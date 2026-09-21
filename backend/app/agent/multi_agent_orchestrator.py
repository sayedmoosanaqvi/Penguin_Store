from langgraph.checkpoint.memory import MemorySaver
from typing import Annotated, Sequence, TypedDict, Literal
from langchain_core.messages import BaseMessage
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_groq import ChatGroq
from langgraph.prebuilt import create_react_agent
from pydantic import BaseModel, Field

# 1. Correctly import the vector RAG function from your rag.py file
from app.agent.rag import retrieve_store_knowledge

# 2. Temporary mock tool for logistics to prevent schema crashes
# Replace this later once you write your real tracking function
def check_order_status(order_id: str) -> str:
    """Checks the delivery and tracking status of an order."""
    return f"Order #{order_id} is in transit."

llm = ChatGroq(model="openai/gpt-oss-20b")

class AgentState(TypedDict):
    messages: Annotated[Sequence[BaseMessage], add_messages]
    next_agent: str

class Route(BaseModel):
    next_agent: Literal["RetrievalAgent", "LogisticsAgent", "FINISH"] = Field(
        description="The next agent to route the conversation to."
    )

def retrieval_agent(state: AgentState):
    agent = create_react_agent(llm, tools=[retrieve_store_knowledge]) 
    result = agent.invoke({"messages": state["messages"]})
    return {"messages": result["messages"]}

def logistics_agent(state: AgentState):
    agent = create_react_agent(llm, tools=[check_order_status]) 
    result = agent.invoke({"messages": state["messages"]})
    return {"messages": result["messages"]}

def supervisor_node(state: AgentState):
    system_prompt = (
        "You are the routing supervisor for an e-commerce AI system.\n"
        "1. If the user asks about products, store policies, or general knowledge, route to 'RetrievalAgent'.\n"
        "2. If the user asks about order tracking, checkout, or payments, route to 'LogisticsAgent'.\n"
        "3. If the user's request has been fully answered, route to 'FINISH'."
    )
    
    router = llm.with_structured_output(Route)
    response = router.invoke([{"role": "system", "content": system_prompt}] + state["messages"])
    
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
        "LogisticsAgent": "LogisticsAgent",
        "FINISH": END
    }
)

workflow.add_edge("RetrievalAgent", "Supervisor")
workflow.add_edge("LogisticsAgent", "Supervisor")

checkpointer = MemorySaver()
multi_agent_app = workflow.compile(checkpointer=checkpointer)