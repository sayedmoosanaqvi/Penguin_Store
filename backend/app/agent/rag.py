import os
import re
from collections import Counter
from math import sqrt


# ===========================================================================
# KNOWLEDGE BASE CONFIGURATION
# ===========================================================================

BASE_DIR = os.path.dirname(
    os.path.dirname(
        os.path.dirname(
            os.path.abspath(__file__)
        )
    )
)

KB_PATH = os.path.join(
    BASE_DIR,
    "knowledge_base.md",
)


# ===========================================================================
# KNOWLEDGE BASE LOADER
# ===========================================================================

def load_knowledge_chunks() -> list[str]:
    """
    Load Penguin Store's knowledge base and split it into policy/document
    chunks.

    This module is intentionally responsible only for knowledge retrieval.
    Product inventory is handled separately by database-backed agent tools.
    """

    if not os.path.exists(KB_PATH):
        print(
            f"[KNOWLEDGE BASE WARNING] "
            f"File not found: {KB_PATH}"
        )
        return []

    try:
        with open(
            KB_PATH,
            "r",
            encoding="utf-8",
        ) as file:
            text = file.read()

    except Exception as exc:
        print(
            f"[KNOWLEDGE BASE ERROR] "
            f"Unable to read knowledge base: {exc}"
        )
        return []

    # Split by Markdown headings or blank paragraphs.
    raw_chunks = re.split(
        r"\n#{1,3}\s+|\n\n+",
        text,
    )

    chunks = [
        chunk.strip()
        for chunk in raw_chunks
        if len(chunk.strip()) > 15
    ]

    return chunks


# ===========================================================================
# LIGHTWEIGHT TEXT PROCESSING
#
# We deliberately use a lightweight implementation rather than loading
# another embedding model because the Render instance has limited RAM.
# ===========================================================================

def _tokenize(text: str) -> list[str]:
    """
    Convert text into normalized searchable terms.
    """

    stop_words = {
        "the",
        "a",
        "an",
        "and",
        "or",
        "but",
        "in",
        "on",
        "at",
        "to",
        "for",
        "with",
        "is",
        "are",
        "was",
        "were",
        "you",
        "your",
        "our",
        "we",
        "of",
        "it",
    }

    words = re.findall(
        r"\w+",
        text.lower(),
    )

    return [
        word
        for word in words
        if word not in stop_words
        and len(word) > 2
    ]


def _compute_cosine_similarity(
    vec1: Counter,
    vec2: Counter,
) -> float:
    """
    Calculate cosine similarity between two sparse term-frequency vectors.
    """

    intersection = (
        set(vec1.keys())
        & set(vec2.keys())
    )

    numerator = sum(
        vec1[token] * vec2[token]
        for token in intersection
    )

    sum1 = sum(
        value ** 2
        for value in vec1.values()
    )

    sum2 = sum(
        value ** 2
        for value in vec2.values()
    )

    if sum1 == 0 or sum2 == 0:
        return 0.0

    return numerator / (
        sqrt(sum1)
        * sqrt(sum2)
    )


# ===========================================================================
# STORE KNOWLEDGE RETRIEVAL
# ===========================================================================

def retrieve_store_knowledge(
    query: str,
    k: int = 3,
) -> str:
    """
    Search Penguin Store's knowledge base.

    Intended for questions such as:

    - What is your return policy?
    - Do you offer refunds?
    - What payment methods are supported?
    - What is your warranty policy?
    - How does shipping work?

    Product inventory must NOT be searched here.
    """

    print(
        f"\n[KNOWLEDGE RAG] Query: '{query}'"
    )

    try:
        chunks = load_knowledge_chunks()

        if not chunks:
            return (
                "The Penguin Store knowledge base "
                "is currently unavailable."
            )

        query_tokens = _tokenize(query)

        if not query_tokens:
            return (
                "No relevant store policy "
                "could be identified."
            )

        query_vector = Counter(
            query_tokens
        )

        scored_chunks = []

        for chunk in chunks:
            chunk_tokens = _tokenize(
                chunk
            )

            if not chunk_tokens:
                continue

            chunk_vector = Counter(
                chunk_tokens
            )

            score = (
                _compute_cosine_similarity(
                    query_vector,
                    chunk_vector,
                )
            )

            scored_chunks.append(
                (
                    score,
                    chunk,
                )
            )

        scored_chunks.sort(
            key=lambda item: item[0],
            reverse=True,
        )

        top_chunks = [
            chunk
            for score, chunk
            in scored_chunks[:k]
            if score > 0.0
        ]

        if not top_chunks:
            return (
                "No matching information was found "
                "in the Penguin Store knowledge base."
            )

        context = "\n\n".join(
            top_chunks
        )

        print(
            "[KNOWLEDGE RAG RESULT]\n"
            f"{context}\n"
        )

        return context

    except Exception as exc:
        print(
            f"[KNOWLEDGE RAG ERROR] {exc}"
        )

        return (
            "An error occurred while retrieving "
            "Penguin Store policy information."
        )