"""Voice Intelligence & Multimodal Search API Router.

Provides:
  - POST /api/v1/ai/transcribe   (Groq Whisper whisper-large-v3 primary + turbo fallback,
                                   catalog-seeded prompt, silence/hallucination guard,
                                   and post-ASR fuzzy catalog + spoken-price query repair)
  - POST /api/v1/ai/speak        (Groq Orpheus Neural TTS <=195 chars with clean client fallback)
  - POST /api/v1/search/multimodal (ResNet-50 pgvector + Text/Voice Intent Reciprocal Rank Fusion)
"""

from __future__ import annotations

import io
import logging
import os
import re
import time
from difflib import SequenceMatcher
from threading import Lock
from typing import Any, Optional

import groq
import httpx
from fastapi import APIRouter, File, Form, HTTPException, Response, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from app.services.ai_telemetry_service import record_voice_metric
from app.services.multimodal_search_service import execute_multimodal_rrf_search

logger = logging.getLogger("uvicorn.error")

router = APIRouter(tags=["Voice Intelligence & Multimodal Search"])

MAX_AUDIO_BYTES = 10 * 1024 * 1024  # 10 MB
MAX_IMAGE_BYTES = 8 * 1024 * 1024   # 8 MB
MIN_SPEECH_DURATION_SECONDS = 0.38
ALLOWED_AUDIO_EXTENSIONS = {
    ".webm",
    ".wav",
    ".mp3",
    ".m4a",
    ".ogg",
    ".mp4",
    ".aac",
    ".mpeg",
    ".flac",
}

# Circuit-breaker timestamp when Groq Orpheus TTS requires playground terms acceptance
_orpheus_blocked_until: float = 0.0

# Cached catalog vocabulary for Whisper domain prompt & post-ASR fuzzy repair
_VOCAB_LOCK = Lock()
_VOCAB_LOADED_AT: float = 0.0
_VOCAB_TTL_SECONDS: float = 180.0
_CACHED_WHISPER_PROMPT: str = (
    "Penguin Store e-commerce voice search. Brands & items: AirPods, Sony, Nike, Apple, "
    "wireless headphones, earbuds, smartwatch, sneakers, running shoes, jacket, shirt, "
    "sunglasses, fragrance, skincare, laptop, smartphone, backpack, 3D model, B2B wholesale, "
    "under $100, under $250, add to cart."
)
_CACHED_CATALOG_VOCAB: set[str] = set()

_STOPWORDS_NO_FUZZY = {
    "under", "below", "less", "than", "over", "above", "between", "around", "about",
    "within", "budget", "maximum", "minimum", "dollars", "dollar", "bucks", "price",
    "priced", "cheap", "cheapest", "best", "good", "great", "rated", "rating",
    "with", "without", "from", "into", "show", "find", "search", "looking", "want",
    "need", "like", "this", "that", "these", "those", "have", "more", "most", "only",
    "model", "models", "view", "twin", "store", "penguin", "cart", "order", "items",
    "product", "products", "similar", "style", "color", "black", "white", "blue",
    "green", "brown", "silver", "golden", "mens", "womens", "please",
}

_WHISPER_HALLUCINATION_EXACT = {
    "thank you",
    "thank you very much",
    "thank you so much",
    "thanks",
    "thanks for watching",
    "thank you for watching",
    "thanks for listening",
    "please subscribe",
    "subscribe",
    "like and subscribe",
    "you",
    "bye",
    "bye bye",
    "goodbye",
    "subtitles by",
    "amara org",
    "subtitles by the amara org community",
    "translated by",
    "mbc",
    "so",
    "uh",
    "um",
    "hmm",
    "oh",
    "ah",
}

_WHISPER_HALLUCINATION_SUBSTRINGS = (
    "thanks for watching",
    "thank you for watching",
    "subtitles by",
    "amara.org",
    "please subscribe",
    "transcribed by",
)

_UNITS_MAP = {
    "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
    "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
}
_TENS_MAP = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
_ALL_NUMBER_WORDS = set(_UNITS_MAP.keys()) | set(_TENS_MAP.keys()) | {"hundred", "thousand", "and", "a"}


def _parse_number_words_tokens(tokens: list[str]) -> Optional[int]:
    """Convert a sequence of English number words (e.g. ['two', 'fifty'] or ['one', 'hundred', 'twenty']) into an integer."""
    clean = [t.lower() for t in tokens if t.lower() not in ("and",)]
    if not clean:
        return None

    # Shorthand spoken hundreds: "two fifty" -> 250, "one twenty five" -> 125
    if (
        len(clean) in (2, 3)
        and clean[0] in _UNITS_MAP
        and 1 <= _UNITS_MAP[clean[0]] <= 9
        and clean[1] in _TENS_MAP
    ):
        val = _UNITS_MAP[clean[0]] * 100 + _TENS_MAP[clean[1]]
        if len(clean) == 3:
            if clean[2] in _UNITS_MAP and 1 <= _UNITS_MAP[clean[2]] <= 9:
                val += _UNITS_MAP[clean[2]]
            else:
                return None
        return val

    total = 0
    current = 0
    matched_any = False
    for tok in clean:
        if tok == "a":
            current = max(current, 1)
            matched_any = True
        elif tok in _UNITS_MAP:
            current += _UNITS_MAP[tok]
            matched_any = True
        elif tok in _TENS_MAP:
            current += _TENS_MAP[tok]
            matched_any = True
        elif tok == "hundred":
            current = (current if current > 0 else 1) * 100
            matched_any = True
        elif tok == "thousand":
            total += (current if current > 0 else 1) * 1000
            current = 0
            matched_any = True
        else:
            return None

    res = total + current
    return res if (matched_any and res > 0) else None


def normalize_spoken_numbers(text: str) -> str:
    """
    Convert spoken price/budget phrases such as:
      - 'under two fifty' -> 'under $250'
      - 'below one hundred dollars' -> 'below $100'
      - 'less than fifty bucks' -> 'less than $50'
      - 'between fifty and two hundred' -> 'between $50 and $200'
    into crisp numeric expressions while leaving normal product words untouched.
    """
    if not text or not text.strip():
        return ""

    out = text

    # Handle "between <num_words> and <num_words>"
    between_pat = re.compile(
        r"\b(between)\s+([a-z]+(?:\s+[a-z]+){0,3})\s+(and|to)\s+([a-z]+(?:\s+[a-z]+){0,3})(?:\s+(?:dollars?|bucks?|usd))?\b",
        flags=re.IGNORECASE,
    )

    def _repl_between(m: re.Match) -> str:
        t1 = [w for w in re.split(r"[\s-]+", m.group(2).strip()) if w]
        t2 = [w for w in re.split(r"[\s-]+", m.group(4).strip()) if w]
        v1 = _parse_number_words_tokens(t1) if all(w.lower() in _ALL_NUMBER_WORDS for w in t1) else None
        v2 = _parse_number_words_tokens(t2) if all(w.lower() in _ALL_NUMBER_WORDS for w in t2) else None
        if v1 is not None and v2 is not None:
            return f"{m.group(1)} ${v1} {m.group(3)} ${v2}"
        return m.group(0)

    out = between_pat.sub(_repl_between, out)

    # Handle "<price_prep> <spoken_number> [dollars|bucks|usd]"
    prep_pat = re.compile(
        r"\b(under|below|less\s+than|over|above|at\s+least|max|maximum|min|minimum|up\s+to|within|around|budget(?:\s+of)?)\s+"
        r"([a-z]+(?:[\s-]+[a-z]+){0,4}?)(?=\s+(?:dollars?|bucks?|usd)\b|\s+(?:with|in|for|and|or|having)\b|[,.!?]|$)",
        flags=re.IGNORECASE,
    )

    def _repl_prep(m: re.Match) -> str:
        prep = m.group(1)
        raw_num = m.group(2).strip()
        words = [w for w in re.split(r"[\s-]+", raw_num) if w]
        num_words: list[str] = []
        trailing: list[str] = []
        for idx, w in enumerate(words):
            if w.lower() in _ALL_NUMBER_WORDS and not trailing:
                num_words.append(w)
            else:
                trailing = words[idx:]
                break
        if not num_words:
            return m.group(0)
        parsed = _parse_number_words_tokens(num_words)
        if parsed is None:
            return m.group(0)
        tail = (" " + " ".join(trailing)) if trailing else ""
        return f"{prep} ${parsed}{tail}"

    out = prep_pat.sub(_repl_prep, out)
    # Clean redundant "$250 dollars" -> "$250"
    out = re.sub(r"\$(\d+(?:\.\d+)?)\s+(?:dollars?|bucks?|usd)\b", r"$\1", out, flags=re.IGNORECASE)

    # Also convert standalone "<spoken_number> dollars/bucks" without preposition
    standalone_pat = re.compile(
        r"\b([a-z]+(?:[\s-]+[a-z]+){0,3})\s+(?:dollars?|bucks?|usd)\b",
        flags=re.IGNORECASE,
    )

    def _repl_standalone(m: re.Match) -> str:
        words = [w for w in re.split(r"[\s-]+", m.group(1).strip()) if w]
        if not words or not all(w.lower() in _ALL_NUMBER_WORDS for w in words):
            return m.group(0)
        parsed = _parse_number_words_tokens(words)
        return f"${parsed}" if parsed is not None else m.group(0)

    out = standalone_pat.sub(_repl_standalone, out)
    return out


def _get_catalog_vocab_and_prompt(
    catalog_products: Optional[list[dict[str, Any]]] = None,
) -> tuple[set[str], str]:
    """Build & cache dynamic Whisper prompt + canonical vocabulary from active Supabase catalog."""
    global _VOCAB_LOADED_AT, _CACHED_WHISPER_PROMPT, _CACHED_CATALOG_VOCAB

    if catalog_products is None:
        now = time.monotonic()
        if _CACHED_CATALOG_VOCAB and (now - _VOCAB_LOADED_AT) < _VOCAB_TTL_SECONDS:
            return _CACHED_CATALOG_VOCAB, _CACHED_WHISPER_PROMPT

    with _VOCAB_LOCK:
        if catalog_products is None:
            now = time.monotonic()
            if _CACHED_CATALOG_VOCAB and (now - _VOCAB_LOADED_AT) < _VOCAB_TTL_SECONDS:
                return _CACHED_CATALOG_VOCAB, _CACHED_WHISPER_PROMPT
            try:
                from app.core.supabase_rest import fetch_products_https

                products = fetch_products_https()
            except Exception:
                products = []
        else:
            products = catalog_products

        base_vocab = {
            "airpods", "headphones", "earbuds", "smartwatch", "sneakers",
            "sunglasses", "fragrance", "fragrances", "perfume", "skincare",
            "smartphone", "smartphones", "laptop", "laptops", "backpack",
            "jacket", "shirts", "shoes", "watches", "accessories", "wholesale",
            "wireless", "bluetooth", "leather", "gaming",
        }
        vocab = set(base_vocab)
        categories_seen: list[str] = []
        title_keywords: list[str] = []
        seen_kw: set[str] = set()

        for p in products:
            cat = str(p.get("category") or "").strip()
            if cat and cat.lower() not in seen_kw:
                seen_kw.add(cat.lower())
                categories_seen.append(cat)
            for raw_tok in re.findall(r"[A-Za-z0-9]+", f"{p.get('name', '')} {cat}"):
                tl = raw_tok.lower()
                if len(tl) >= 4 and tl.isalpha() and tl not in _STOPWORDS_NO_FUZZY:
                    vocab.add(tl)
                    if raw_tok[0].isupper() and tl not in seen_kw and len(title_keywords) < 28:
                        seen_kw.add(tl)
                        title_keywords.append(raw_tok)

        cat_snippet = ", ".join(categories_seen[:12])
        kw_snippet = ", ".join(title_keywords[:22])
        prompt_parts = [
            "Penguin Store shopping search.",
            "Terms: AirPods, wireless headphones, smartwatch, sneakers, jacket, sunglasses, 3D model, B2B wholesale, under $250.",
        ]
        if cat_snippet:
            prompt_parts.append(f"Categories: {cat_snippet}.")
        if kw_snippet:
            prompt_parts.append(f"Catalog: {kw_snippet}.")
        prompt_str = " ".join(prompt_parts)[:760]

        if catalog_products is None:
            _CACHED_CATALOG_VOCAB = vocab
            _CACHED_WHISPER_PROMPT = prompt_str
            _VOCAB_LOADED_AT = time.monotonic()

        return vocab, prompt_str


def _phonetic_group(ch: str) -> str:
    c = ch.lower()
    if c in "aeiou":
        return "vowel"
    if c in "ckq":
        return "k"
    if c in "sz":
        return "s"
    if c in "fpv":
        return "f"
    if c in "gj":
        return "g"
    return c


def repair_voice_query(
    raw_transcript: str,
    catalog_products: Optional[list[dict[str, Any]]] = None,
) -> dict[str, Any]:
    """
    Post-ASR Catalog-Aware Query Repair & Spoken-Price Parser.
    Repairs common Whisper homophones/splits ('ear pods' -> 'AirPods', 'three d' -> '3D'),
    converts spoken numbers ('under two fifty' -> 'under $250'), and fuzzy-matches
    near-miss product tokens against active Supabase catalog vocabulary.
    """
    raw_clean = re.sub(r"\s+", " ", (raw_transcript or "")).strip()
    if not raw_clean:
        return {
            "raw_transcript": "",
            "transcript": "",
            "was_repaired": False,
            "inferred_min_price": None,
            "inferred_max_price": None,
            "inferred_only_3d": False,
        }

    # Strip trailing sentence period added by Whisper on short search queries
    text = re.sub(r"[.]+$", "", raw_clean).strip()

    # 1. Compound & homophone domain replacements
    compound_rules: tuple[tuple[str, str], ...] = (
        (r"\b(?:ear|air|eir|are)\s*[-]?\s*pods?\b", "AirPods"),
        (r"\bearpods?\b", "AirPods"),
        (r"\b(?:three|3)\s*[-]?\s*d\b", "3D"),
        (r"\bhead\s+phones\b", "headphones"),
        (r"\bhead\s+phone\b", "headphone"),
        (r"\bear\s+buds\b", "earbuds"),
        (r"\bear\s+bud\b", "earbud"),
        (r"\bsmart\s+watches\b", "smartwatches"),
        (r"\bsmart\s+watch\b", "smartwatch"),
        (r"\bsun\s+glasses\b", "sunglasses"),
        (r"\bback\s+packs\b", "backpacks"),
        (r"\bback\s+pack\b", "backpack"),
        (r"\bskin\s+care\b", "skincare"),
        (r"\b(?:tee|t)\s+shirts\b", "t-shirts"),
        (r"\b(?:tee|t)\s+shirt\b", "t-shirt"),
        (r"\bi\s+phone\b", "iPhone"),
        (r"\bmac\s+book\b", "MacBook"),
        (r"\bwhole\s+sale\b", "wholesale"),
    )
    for pattern, replacement in compound_rules:
        text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)

    # 2. Spoken price & number normalization ("under two fifty" -> "under $250")
    text = normalize_spoken_numbers(text)

    # 3. Catalog-grounded fuzzy token repair for near-miss product nouns
    vocab, _ = _get_catalog_vocab_and_prompt(catalog_products)

    def _repair_word(match: re.Match) -> str:
        word = match.group(0)
        wl = word.lower()
        if len(wl) < 5 or not wl.isalpha():
            return word
        if wl in vocab or wl in _STOPWORDS_NO_FUZZY or wl in _ALL_NUMBER_WORDS:
            return word
        # Check singular stem already in vocab
        if wl.endswith("s") and wl[:-1] in vocab:
            return word

        best_cand: Optional[str] = None
        best_ratio = 0.84
        w_group = _phonetic_group(wl[0])
        for cand in vocab:
            if abs(len(cand) - len(wl)) > 2:
                continue
            if _phonetic_group(cand[0]) != w_group:
                continue
            ratio = SequenceMatcher(None, wl, cand).ratio()
            if ratio > best_ratio:
                best_ratio = ratio
                best_cand = cand

        if best_cand is None:
            return word
        if best_cand == "airpods":
            return "AirPods"
        return best_cand.capitalize() if word[0].isupper() else best_cand

    repaired = re.sub(r"\b[A-Za-z]{5,}\b", _repair_word, text)
    repaired = re.sub(r"\s+", " ", repaired).strip()

    from app.services.multimodal_search_service import _parse_inline_price_constraints

    inf_min, inf_max, inf_3d = _parse_inline_price_constraints(repaired, None, None)

    return {
        "raw_transcript": raw_clean,
        "transcript": repaired,
        "was_repaired": repaired.lower() != raw_clean.rstrip(".").strip().lower(),
        "inferred_min_price": inf_min,
        "inferred_max_price": inf_max,
        "inferred_only_3d": inf_3d,
    }


def is_whisper_hallucination_or_silence(
    raw_text: str,
    *,
    duration_seconds: float = 1.0,
    avg_no_speech_prob: float = 0.0,
) -> bool:
    """Detect empty clips, sub-380ms taps, high no_speech_prob, and classic Whisper silence hallucinations."""
    if 0.0 < duration_seconds < MIN_SPEECH_DURATION_SECONDS:
        return True

    stripped = (raw_text or "").strip()
    if not stripped:
        return True

    alnum_only = re.sub(r"[^a-zA-Z0-9]+", " ", stripped).strip().lower()
    if not alnum_only:
        return True

    if avg_no_speech_prob >= 0.85 and len(alnum_only) < 24:
        return True

    if alnum_only in _WHISPER_HALLUCINATION_EXACT:
        return True

    lower_raw = stripped.lower()
    for sub in _WHISPER_HALLUCINATION_SUBSTRINGS:
        if sub in lower_raw:
            return True

    return False


def _detect_audio_extension(
    audio_bytes: bytes,
    filename: str,
    content_type: Optional[str] = None,
) -> str:
    """Resolve accurate container extension from magic bytes, Content-Type, or filename."""
    if len(audio_bytes) >= 12:
        if audio_bytes[:4] == b"RIFF" and audio_bytes[8:12] == b"WAVE":
            return ".wav"
        if audio_bytes[:4] == b"\x1a\x45\xdf\xa3":
            return ".webm"
        if audio_bytes[4:8] == b"ftyp":
            return ".mp4"
        if audio_bytes[:4] == b"OggS":
            return ".ogg"
        if audio_bytes[:4] == b"fLaC":
            return ".flac"
    if audio_bytes[:3] == b"ID3" or audio_bytes[:2] in {b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"}:
        return ".mp3"

    ct = (content_type or "").lower()
    if "mp4" in ct or "m4a" in ct or "aac" in ct:
        return ".mp4"
    if "ogg" in ct:
        return ".ogg"
    if "wav" in ct or "wave" in ct:
        return ".wav"
    if "webm" in ct:
        return ".webm"
    if "mpeg" in ct or "mp3" in ct:
        return ".mp3"

    ext = os.path.splitext(filename or "")[1].lower()
    if ext in ALLOWED_AUDIO_EXTENSIONS:
        return ext
    return ".webm"


class SpeakRequest(BaseModel):
    text: str = Field(..., min_length=1, max_length=1200)
    voice: str = Field(default="troy", max_length=32)


def _strip_markdown_for_tts(raw: str) -> str:
    text = re.sub(r"```[\s\S]*?```", " ", raw)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[*_#`~>|]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _transcribe_with_groq_sync(
    *,
    audio_bytes: bytes,
    filename: str,
    language: Optional[str],
) -> dict[str, Any]:
    api_key = (os.getenv("GROQ_API_KEY") or "").strip()
    if not api_key:
        raise RuntimeError("GROQ_API_KEY is not configured in backend environment.")

    client = groq.Groq(api_key=api_key, timeout=22.0)

    ext = os.path.splitext(filename)[1].lower()
    safe_name = filename if ext in ALLOWED_AUDIO_EXTENSIONS else "speech.webm"
    _, domain_prompt = _get_catalog_vocab_and_prompt()

    last_exc: Exception | None = None
    # Primary: full `whisper-large-v3` for highest accuracy; automatic fallback to `whisper-large-v3-turbo`
    for model_id in ("whisper-large-v3", "whisper-large-v3-turbo"):
        try:
            buf = io.BytesIO(audio_bytes)
            buf.name = safe_name
            kwargs: dict[str, Any] = {
                "file": (safe_name, buf),
                "model": model_id,
                "response_format": "verbose_json",
                "temperature": 0.0,
                "prompt": domain_prompt,
            }
            if language and language.strip():
                kwargs["language"] = language.strip()[:8]
            result = client.audio.transcriptions.create(**kwargs)
            text_out = getattr(result, "text", None) or (
                result.get("text") if isinstance(result, dict) else ""
            )
            lang_out = getattr(result, "language", None) or (
                result.get("language") if isinstance(result, dict) else (language or "en")
            )
            dur_val = getattr(result, "duration", None)
            if dur_val is None and isinstance(result, dict):
                dur_val = result.get("duration")
            duration_s = float(dur_val) if dur_val is not None else 1.0

            segments = getattr(result, "segments", None)
            if segments is None and isinstance(result, dict):
                segments = result.get("segments")
            no_speech_probs: list[float] = []
            if isinstance(segments, list):
                for seg in segments:
                    nsp = (
                        seg.get("no_speech_prob")
                        if isinstance(seg, dict)
                        else getattr(seg, "no_speech_prob", None)
                    )
                    if nsp is not None:
                        try:
                            no_speech_probs.append(float(nsp))
                        except (TypeError, ValueError):
                            pass
            avg_nsp = (
                sum(no_speech_probs) / len(no_speech_probs)
                if no_speech_probs
                else 0.0
            )

            return {
                "text": str(text_out or "").strip(),
                "language": str(lang_out or "en"),
                "duration": duration_s,
                "avg_no_speech_prob": avg_nsp,
                "model_used": model_id,
            }
        except Exception as exc:
            last_exc = exc
            logger.warning("Groq STT model %s fallback check: %s", model_id, exc)
            continue

    if last_exc is not None:
        raise last_exc
    return {
        "text": "",
        "language": language or "en",
        "duration": 0.0,
        "avg_no_speech_prob": 1.0,
        "model_used": "none",
    }


@router.post("/api/v1/ai/transcribe")
async def transcribe_audio(
    file: UploadFile = File(...),
    language: Optional[str] = Form(default=None),
):
    """
    Transcribe spoken microphone audio from Flutter Web/Mobile using Groq Whisper
    (`whisper-large-v3` primary + `whisper-large-v3-turbo` fallback) with catalog
    vocabulary prompting, silence/hallucination filtering, and fuzzy query repair.
    """
    started = time.perf_counter()

    audio_bytes = await file.read(MAX_AUDIO_BYTES + 1)
    if len(audio_bytes) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail="Audio clip exceeds the 10 MB upload limit.",
        )

    # Gracefully handle silent / empty quick taps (< ~400ms / tiny byte buffers) without throwing 500s
    if len(audio_bytes) < 512:
        return {
            "transcript": "",
            "raw_transcript": "",
            "language": language or "en",
            "latency_ms": 0.0,
            "empty_clip": True,
            "was_repaired": False,
            "message": "Didn't catch that clearly — please speak closer to the mic and try again.",
        }

    filename = (file.filename or "recording.webm").strip() or "recording.webm"
    detected_ext = _detect_audio_extension(
        audio_bytes=audio_bytes,
        filename=filename,
        content_type=file.content_type,
    )
    resolved_filename = f"recording{detected_ext}"

    try:
        stt_out = await run_in_threadpool(
            _transcribe_with_groq_sync,
            audio_bytes=audio_bytes,
            filename=resolved_filename,
            language=language,
        )
        raw_transcript = str(stt_out.get("text") or "").strip()
        detected_lang = str(stt_out.get("language") or language or "en")
        duration_s = float(stt_out.get("duration") or 1.0)
        avg_nsp = float(stt_out.get("avg_no_speech_prob") or 0.0)
        model_used = str(stt_out.get("model_used") or "whisper-large-v3")
        latency_ms = round((time.perf_counter() - started) * 1000.0, 2)

        if is_whisper_hallucination_or_silence(
            raw_transcript,
            duration_seconds=duration_s,
            avg_no_speech_prob=avg_nsp,
        ):
            return {
                "transcript": "",
                "raw_transcript": raw_transcript,
                "language": detected_lang,
                "latency_ms": latency_ms,
                "empty_clip": True,
                "was_repaired": False,
                "model_used": model_used,
                "message": "Didn't catch that clearly — please speak closer to the mic and try again.",
            }

        repaired_info = await run_in_threadpool(repair_voice_query, raw_transcript)

        try:
            record_voice_metric(
                operation="whisper_large_v3_stt",
                latency_ms=latency_ms,
                success=True,
                language=detected_lang,
                chars_or_bytes=len(audio_bytes),
            )
        except Exception:
            pass

        return {
            "transcript": repaired_info["transcript"],
            "raw_transcript": repaired_info["raw_transcript"],
            "was_repaired": repaired_info["was_repaired"],
            "inferred_min_price": repaired_info["inferred_min_price"],
            "inferred_max_price": repaired_info["inferred_max_price"],
            "inferred_only_3d": repaired_info["inferred_only_3d"],
            "language": detected_lang,
            "latency_ms": latency_ms,
            "empty_clip": False,
            "model_used": model_used,
        }
    except Exception as exc:
        latency_ms = round((time.perf_counter() - started) * 1000.0, 2)
        logger.warning("STT transcription failed cleanly: %s", exc)
        try:
            record_voice_metric(
                operation="whisper_large_v3_stt",
                latency_ms=latency_ms,
                success=False,
                chars_or_bytes=len(audio_bytes),
            )
        except Exception:
            pass
        raise HTTPException(
            status_code=503,
            detail="Voice transcription is temporarily unavailable. Please try typing your query.",
        )


@router.post("/api/v1/ai/speak")
async def synthesize_speech(payload: SpeakRequest):
    """
    Synthesize short expressive neural speech (<= 195 chars) via Groq
    `canopylabs/orpheus-v1-english` with a strict 4-second timeout and seamless
    client-TTS fallback JSON response on long text or rate limits.
    """
    global _orpheus_blocked_until
    started = time.perf_counter()
    clean_text = _strip_markdown_for_tts(payload.text)
    api_key = (os.getenv("GROQ_API_KEY") or "").strip()

    if not clean_text or len(clean_text) > 195 or not api_key:
        return JSONResponse(
            status_code=200,
            content={
                "fallback_to_client_tts": True,
                "reason": "length_exceeded" if len(clean_text) > 195 else "unconfigured",
            },
        )

    if time.monotonic() < _orpheus_blocked_until:
        return JSONResponse(
            status_code=200,
            content={
                "fallback_to_client_tts": True,
                "reason": "terms_not_accepted",
            },
        )

    allowed_voices = {"troy", "diana", "autumn", "austin", "daniel", "hannah"}
    voice_name = payload.voice.strip().lower()
    if voice_name not in allowed_voices:
        voice_name = "troy"

    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.post(
                "https://api.groq.com/openai/v1/audio/speech",
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": "canopylabs/orpheus-v1-english",
                    "input": clean_text,
                    "voice": voice_name,
                    "response_format": "wav",
                },
            )

        latency_ms = round((time.perf_counter() - started) * 1000.0, 2)
        if resp.status_code == 200 and len(resp.content) > 44:
            try:
                record_voice_metric(
                    operation="orpheus_neural_tts",
                    latency_ms=latency_ms,
                    success=True,
                    chars_or_bytes=len(resp.content),
                )
            except Exception:
                pass
            return Response(
                content=resp.content,
                media_type="audio/wav",
                headers={
                    "X-TTS-Engine": "groq-orpheus",
                    "Cache-Control": "no-store",
                },
            )

        if resp.status_code == 400 and "terms" in resp.text.lower():
            _orpheus_blocked_until = time.monotonic() + 600.0
            logger.info("Groq Orpheus TTS terms not accepted; caching fallback for 10m")
            return JSONResponse(
                status_code=200,
                content={
                    "fallback_to_client_tts": True,
                    "reason": "terms_not_accepted",
                },
            )

        logger.info("Groq Orpheus TTS fallback triggered (status=%s)", resp.status_code)
    except Exception as exc:
        logger.info("Groq Orpheus TTS unavailable, falling back to client TTS: %s", exc)

    return JSONResponse(
        status_code=200,
        content={
            "fallback_to_client_tts": True,
            "reason": "upstream_fallback",
        },
    )


@router.post("/api/v1/search/multimodal")
@router.post("/api/search/multimodal")
async def multimodal_rrf_search(
    file: Optional[UploadFile] = File(default=None),
    query: Optional[str] = Form(default=None),
    min_price: Optional[float] = Form(default=None),
    max_price: Optional[float] = Form(default=None),
    category: Optional[str] = Form(default=None),
    only_3d: bool = Form(default=False),
):
    """
    Hybrid Image + Voice/Text Search using ResNet-50 ONNX pgvector similarity
    combined with semantic/price filtering via Reciprocal Rank Fusion (RRF).
    """
    image_bytes: Optional[bytes] = None
    if file is not None:
        raw = await file.read(MAX_IMAGE_BYTES + 1)
        if len(raw) > MAX_IMAGE_BYTES:
            raise HTTPException(
                status_code=413,
                detail="Image exceeds the 8 MB limit.",
            )
        if raw:
            from app.core.upload_security import validate_image_upload

            validate_image_upload(
                raw,
                file.filename,
                max_bytes=MAX_IMAGE_BYTES,
                require_extension=False,
            )
            image_bytes = raw

    if not image_bytes and not (query and query.strip()) and max_price is None and not category:
        raise HTTPException(
            status_code=400,
            detail="Provide an image, a search query, or filter constraints.",
        )

    return await run_in_threadpool(
        execute_multimodal_rrf_search,
        image_bytes=image_bytes,
        query_text=query,
        min_price=min_price,
        max_price=max_price,
        category=category,
        only_3d=only_3d,
    )
