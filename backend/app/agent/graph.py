import os
from dotenv import load_dotenv

# 1. Force load the .env file immediately so the API key is caught before Groq initializes
load_dotenv()

from langgraph.graph import StateGraph, END
from langgraph.prebuilt import ToolNode, tools_condition
from langgraph.checkpoint.memory import MemorySaver
from langchain_core.messages import SystemMessage
from app.agent.state import AgentState

# 2. Import all tools from your tools file (Inventory, Cart, Orders, Knowledge Base RAG)
from app.agent.tools import search_inventory, add_to_cart, check_order_status, search_knowledge_base
from langchain_groq import ChatGroq

# 3. Initialize the LLM with the latest supported Groq model
llm = ChatGroq(
    api_key=os.getenv("GROQ_API_KEY"),
    model="openai/gpt-oss-120b",
    temperature=0,
    max_retries=5,
    timeout=60.0
)

# 4. Bind all tools to the LLM
tools = [search_inventory, add_to_cart, check_order_status, search_knowledge_base]
llm_with_tools = llm.bind_tools(tools)

# 5. Strict system prompt updated with RAG & Ambiguity Rules
SYSTEM_PROMPT = SystemMessage(
    content="""You are the official AI Personal Shopper for Penguin Store.
Your rules:
1. INVENTORY: Always use `search_inventory` to find products. Use the `search_term` argument to find specific items by name (e.g., 'perfume', 'boots').
2. ONLY recommend products returned by `search_inventory`. NEVER invent or hallucinate products.
3. CART ACTIONS: If the user explicitly wants to buy an item, use the `add_to_cart` tool with the exact product_id.
4. AMBIGUITY RULE: If a user asks to "add the perfume to cart" but you previously showed them MULTIPLE perfumes, DO NOT GUESS. You MUST ask the user to clarify exactly which one they want before calling the cart tool.
5. ORDER TRACKING: If a user asks about order status or package delivery, use `check_order_status`. Ask for the Order ID first if not provided.
6. KNOWLEDGE BASE (RAG): If the user asks about store policies, return windows, warranties, payment security, or fulfillment locations, you MUST use the `search_knowledge_base` tool to retrieve official facts. Never guess store policies.
7. Keep your responses friendly, concise, and include exact prices in USD where applicable.
8. SHIPPING TIMES: 
   - 'IN_HOUSE': Ships from Sargodha warehouse, arrives in 1-2 business days.
   - 'DROPSHIP': Dispatched from international partners, takes 7-10 business days."""
)

# 6. Agent reasoning node
def chatbot(state: AgentState):
    messages = [SYSTEM_PROMPT] + list(state["messages"])
    response = llm_with_tools.invoke(messages)
    return {"messages": [response]}

# 7. Build graph
graph_builder = StateGraph(AgentState)
graph_builder.add_node("chatbot", chatbot)
graph_builder.add_node("tools", ToolNode(tools=tools))

graph_builder.add_conditional_edges("chatbot", tools_condition)
graph_builder.add_edge("tools", "chatbot")
graph_builder.set_entry_point("chatbot")

# 8. Checkpointer memory
memory = MemorySaver()
agent_app = graph_builder.compile(checkpointer=memory)