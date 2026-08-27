from langgraph.graph import StateGraph, END
from langgraph.prebuilt import ToolNode, tools_condition
from langgraph.checkpoint.memory import MemorySaver
from langchain_openai import ChatOpenAI
from langchain_core.messages import SystemMessage
from app.agent.state import AgentState
from app.agent.tools import search_inventory

# 1. Initialize cloud-ready model (reads OPENAI_API_KEY from environment variables)
llm = ChatOpenAI(
    model="gpt-4o-mini", 
    temperature=0
)

tools = [search_inventory]
llm_with_tools = llm.bind_tools(tools)

# 2. Strict system prompt for Penguin Store
SYSTEM_PROMPT = SystemMessage(
    content="""You are the official AI Personal Shopper for Penguin Store.
Your rules:
1. Always use the `search_inventory` tool to search for products when a user asks about items, prices, or recommendations.
2. ONLY recommend products returned by the `search_inventory` tool. NEVER invent or hallucinate products that are not in the store database.
3. If no products match the criteria, clearly tell the user that Penguin Store does not currently have that item in stock.
4. Keep your responses friendly, concise, and include exact prices in USD.
5. SHIPPING TIMES: If a user asks about delivery, check the product's 'fulfillment_type':
   - 'IN_HOUSE': Explain that it ships directly from our Sargodha warehouse and arrives in 1-2 business days.
   - 'DROPSHIP': Explain that it is dispatched directly from our international supplier partners and takes 7-10 business days."""
)

# 3. Agent reasoning node
def chatbot(state: AgentState):
    messages = [SYSTEM_PROMPT] + list(state["messages"])
    response = llm_with_tools.invoke(messages)
    return {"messages": [response]}

# 4. Build graph
graph_builder = StateGraph(AgentState)
graph_builder.add_node("chatbot", chatbot)
graph_builder.add_node("tools", ToolNode(tools=tools))

graph_builder.add_conditional_edges("chatbot", tools_condition)
graph_builder.add_edge("tools", "chatbot")
graph_builder.set_entry_point("chatbot")

# 5. Checkpointer memory
memory = MemorySaver()
agent_app = graph_builder.compile(checkpointer=memory)