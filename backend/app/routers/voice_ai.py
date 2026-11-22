"""Voice Intelligence & Multimodal Search API Router.

Provides:
  - POST /api/v1/ai/transcribe   (Groq Whisper whisper-large-v3-turbo STT + v3 fallback)
  - POST /api/v1/ai/speak        (Groq Orpheus Neural TTS <=195 chars with clean client fallback)
  - POST /api/v1/search/multimodal (ResNet-50 pgvector + Text/Voice Intent Reciprocal Rank Fusion)
"""

from __future__ import annotations

import io
import logging
import os
import re
import time
from typing import Optional

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
) -> tuple[str, str]:
    api_key = (os.getenv("GROQ_API_KEY") or "").strip()
    if not api_key:
        raise RuntimeError("GROQ_API_KEY is not configured in backend environment.")

    client = groq.Groq(api_key=api_key, timeout=22.0)

    ext = os.path.splitext(filename)[1].lower()
    safe_name = filename if ext in ALLOWED_AUDIO_EXTENSIONS else "speech.webm"

    last_exc: Exception | None = None
    for model_id in ("whisper-large-v3-turbo", "whisper-large-v3"):
        try:
            buf = io.BytesIO(audio_bytes)
            buf.name = safe_name
            kwargs: dict = {
                "file": (safe_name, buf),
                "model": model_id,
                "response_format": "verbose_json",
                "temperature": 0.0,
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
            return str(text_out or "").strip(), str(lang_out or "en")
        except Exception as exc:
            last_exc = exc
            logger.warning("Groq STT model %s fallback check: %s", model_id, exc)
            continue

    if last_exc is not None:
        raise last_exc
    return "", language or "en"


@router.post("/api/v1/ai/transcribe")
async def transcribe_audio(
    file: UploadFile = File(...),
    language: Optional[str] = Form(default=None),
):
    """
    Transcribe spoken microphone audio from Flutter Web/Mobile using Groq Whisper
    (`whisper-large-v3-turbo` with `whisper-large-v3` fallback).
    """
    started = time.perf_counter()

    audio_bytes = await file.read(MAX_AUDIO_BYTES + 1)
    if len(audio_bytes) > MAX_AUDIO_BYTES:
        raise HTTPException(
            status_code=413,
            detail="Audio clip exceeds the 10 MB upload limit.",
        )

    # Gracefully handle silent / empty quick taps without throwing errors
    if len(audio_bytes) < 128:
        return {
            "transcript": "",
            "language": language or "en",
            "latency_ms": 0.0,
            "empty_clip": True,
        }

    filename = (file.filename or "voice_query.webm").strip() or "voice_query.webm"

    try:
        transcript, detected_lang = await run_in_threadpool(
            _transcribe_with_groq_sync,
            audio_bytes=audio_bytes,
            filename=filename,
            language=language,
        )
        latency_ms = round((time.perf_counter() - started) * 1000.0, 2)
        try:
            record_voice_metric(
                operation="whisper_large_v3_turbo_stt",
                latency_ms=latency_ms,
                success=True,
                language=detected_lang,
                chars_or_bytes=len(audio_bytes),
            )
        except Exception:
            pass

        return {
            "transcript": transcript,
            "language": detected_lang,
            "latency_ms": latency_ms,
        }
    except Exception as exc:
        latency_ms = round((time.perf_counter() - started) * 1000.0, 2)
        logger.warning("STT transcription failed cleanly: %s", exc)
        try:
            record_voice_metric(
                operation="whisper_large_v3_turbo_stt",
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
