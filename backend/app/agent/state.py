from typing import TypedDict, Annotated, Sequence
from langchain_core.messages import BaseMessage
import operator

class AgentState(TypedDict):
    # The 'messages' list stores the conversation history.
    # The operator.add ensures new messages are appended rather than overwriting old ones.
    messages: Annotated[Sequence[BaseMessage], operator.add]