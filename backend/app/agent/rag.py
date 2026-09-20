import os
import re
from math import log, sqrt
from collections import Counter

BASE_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KB_PATH = os.path.join(BASE_DIR, "knowledge_base.md")

def load_knowledge_chunks():
    """Loads and splits the knowledge base markdown into semantic chunks."""
    if not os.path.exists(KB_PATH):
        return []
    
    with open(KB_PATH, "r", encoding="utf-8") as f:
        text = f.read()
        
    # Split document by headers or double newlines into clean policy sections
    raw_chunks = re.split(r'\n#{1,3}\s+|\n\n+', text)
    chunks = [chunk.strip() for chunk in raw_chunks if len(chunk.strip()) > 15]
    return chunks

def _tokenize(text: str):
    """Simple text tokenizer removing common stop words."""
    stop_words = {"the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "with", "is", "are", "you", "your", "our"}
    words = re.findall(r'\w+', text.lower())
    return [w for w in words if w not in stop_words and len(w) > 2]

def _compute_cosine_similarity(vec1, vec2):
    """Computes mathematical cosine similarity between two sparse term vectors."""
    intersection = set(vec1.keys()) & set(vec2.keys())
    numerator = sum(vec1[x] * vec2[x] for x in intersection)
    
    sum1 = sum(v ** 2 for v in vec1.values())
    sum2 = sum(v ** 2 for v in vec2.values())
    
    if sum1 == 0 or sum2 == 0:
        return 0.0
    return numerator / (sqrt(sum1) * sqrt(sum2))

def retrieve_store_knowledge(query: str, k: int = 2) -> str:
    """
    Performs true Pure-Python Vector-Space Semantic Search using TF and Cosine Similarity.
    Requires zero external pip packages and works completely offline.
    """
    print(f"\n[PURE-PYTHON VECTOR RAG] Query: '{query}'")
    try:
        chunks = load_knowledge_chunks()
        if not chunks:
            return "Knowledge base is empty."
        
        query_tokens = _tokenize(query)
        if not query_tokens:
            return chunks[0] if chunks else "No information available."
        
        # Build query vector (Term Frequency)
        query_vector = Counter(query_tokens)
        
        scored_chunks = []
        for chunk in chunks:
            chunk_tokens = _tokenize(chunk)
            if not chunk_tokens:
                continue
            
            chunk_vector = Counter(chunk_tokens)
            score = _compute_cosine_similarity(query_vector, chunk_vector)
            scored_chunks.append((score, chunk))
            
        # Sort by highest cosine similarity score
        scored_chunks.sort(key=lambda x: x[0], reverse=True)
        
        # Select top-k chunks
        top_chunks = [chunk for score, chunk in scored_chunks[:k] if score > 0.0]
        
        # Fallback if query terms don't directly overlap
        if not top_chunks:
            top_chunks = chunks[:k]
            
        context = "\n\n".join(top_chunks)
        print(f"[VECTOR RAG RESULT] Matched Chunks:\n{context}\n")
        return context
    except Exception as e:
        print(f"[VECTOR RAG ERROR] {str(e)}")
        return "Error retrieving store policies."