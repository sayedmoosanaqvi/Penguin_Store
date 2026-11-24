"""Binary magic-byte and size validation for uploaded media and 3D GLB assets."""

from __future__ import annotations

import os
import struct
from fastapi import HTTPException

MAX_IMAGE_UPLOAD_BYTES = 10 * 1024 * 1024  # 10 MB
MAX_GLB_UPLOAD_BYTES = 25 * 1024 * 1024    # 25 MB

ALLOWED_IMAGE_EXTENSIONS: dict[str, str] = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".avif": "image/avif",
}


def sniff_image_format(data: bytes) -> tuple[str, str] | None:
    """Inspect binary magic bytes to verify genuine image container format."""
    if len(data) < 8:
        return None

    # PNG: 89 50 4E 47 0D 0A 1A 0A
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png", "image/png"

    # JPEG: FF D8 FF
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg", "image/jpeg"

    # GIF87a / GIF89a
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif", "image/gif"

    # WebP: RIFF....WEBP
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp", "image/webp"

    # AVIF: ISO BMFF 'ftyp' box with avif/avis/mif1 brand
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brand = data[8:16]
        if any(tag in brand for tag in (b"avif", b"avis", b"mif1", b"heic")):
            return ".avif", "image/avif"

    return None


def validate_image_upload(
    file_bytes: bytes,
    filename: str | None = None,
    *,
    max_bytes: int = MAX_IMAGE_UPLOAD_BYTES,
    require_extension: bool = True,
) -> tuple[str, str]:
    """
    Validate both filename extension (when required) and binary magic bytes
    for uploaded images. Rejects polyglots, executables, SVG scripts, and
    oversized payloads.
    """
    if not file_bytes:
        raise HTTPException(status_code=400, detail="Uploaded image file is empty.")

    if len(file_bytes) > max_bytes:
        limit_mb = max(1, max_bytes // (1024 * 1024))
        raise HTTPException(
            status_code=413,
            detail=f"Image exceeds the {limit_mb} MB upload limit.",
        )

    if require_extension:
        if not filename:
            raise HTTPException(status_code=400, detail="Filename is missing.")
        ext = os.path.splitext(filename)[1].lower()
        if ext not in ALLOWED_IMAGE_EXTENSIONS:
            raise HTTPException(
                status_code=415,
                detail="Unsupported image format. Use JPG, PNG, WEBP, GIF, or AVIF.",
            )

    detected = sniff_image_format(file_bytes)
    if detected is None:
        raise HTTPException(
            status_code=415,
            detail="Invalid image binary header. File content does not match a supported image format.",
        )

    return detected


def validate_glb_upload(
    file_bytes: bytes,
    filename: str | None = None,
    *,
    max_bytes: int = MAX_GLB_UPLOAD_BYTES,
) -> None:
    """
    Validate `.glb` extension, size cap (25 MB default), and Khronos glTF 2.0
    binary magic header (`b'glTF'`, version 2, declared byte length).
    """
    if not filename or not filename.lower().endswith(".glb"):
        raise HTTPException(status_code=415, detail="Upload a valid .glb 3D model file.")

    if not file_bytes:
        raise HTTPException(status_code=400, detail="Uploaded GLB file is empty.")

    if len(file_bytes) > max_bytes:
        limit_mb = max(1, max_bytes // (1024 * 1024))
        raise HTTPException(
            status_code=413,
            detail=f"GLB exceeds the {limit_mb} MB upload limit.",
        )

    if len(file_bytes) < 12 or file_bytes[:4] != b"glTF":
        raise HTTPException(
            status_code=422,
            detail="Invalid GLB magic header (expected Khronos 'glTF' binary container).",
        )

    magic, version, declared_length = struct.unpack("<4sII", file_bytes[:12])
    if magic != b"glTF" or version != 2 or declared_length > len(file_bytes) or declared_length < 12:
        raise HTTPException(
            status_code=422,
            detail="Malformed GLB 2.0 header or truncated binary payload.",
        )
