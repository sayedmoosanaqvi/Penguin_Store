"""
GLB optimizer for Penguin Store 3D uploads.

Downloaded GLB files from the internet frequently embed 2K/4K textures that
make a model 20-80 MB and slow to open. This module re-encodes every embedded
texture so that its longest side is at most ``MAX_TEXTURE_SIZE`` (512 px by
default), rebuilds the binary chunk and returns a smaller, valid GLB 2.0.

It never touches geometry, materials, animations or node transforms, and any
failure falls back to the original bytes so uploads never break.
"""

from __future__ import annotations

import io
import json
import logging
import struct
from typing import Any

from PIL import Image

logger = logging.getLogger(__name__)

MAX_TEXTURE_SIZE = 512

_GLB_MAGIC = 0x46546C67  # "glTF"
_CHUNK_JSON = 0x4E4F534A
_CHUNK_BIN = 0x004E4942


class GLBError(ValueError):
    """Raised when the uploaded bytes are not a usable GLB 2.0 file."""


def _pad4(data: bytes, pad: bytes) -> bytes:
    remainder = len(data) % 4
    if remainder:
        data += pad * (4 - remainder)
    return data


def parse_glb(content: bytes) -> tuple[dict[str, Any], bytes]:
    """Return (gltf_json, bin_chunk) for a GLB 2.0 file."""
    if len(content) < 20:
        raise GLBError("File is too small to be a GLB.")

    magic, version, length = struct.unpack_from("<III", content, 0)

    if magic != _GLB_MAGIC:
        raise GLBError("Not a GLB file (bad magic).")
    if version != 2:
        raise GLBError("Only GLB 2.0 files are supported.")
    if length != len(content):
        raise GLBError("GLB length header does not match file size.")

    offset = 12
    gltf: dict[str, Any] | None = None
    binary = b""

    while offset + 8 <= len(content):
        chunk_len, chunk_type = struct.unpack_from("<II", content, offset)
        offset += 8
        chunk = content[offset: offset + chunk_len]
        if len(chunk) != chunk_len:
            raise GLBError("Truncated GLB chunk.")
        offset += chunk_len

        if chunk_type == _CHUNK_JSON and gltf is None:
            try:
                gltf = json.loads(chunk.decode("utf-8").rstrip(" \t\r\n\x00"))
            except Exception as exc:  # noqa: BLE001
                raise GLBError("GLB JSON chunk is invalid.") from exc
        elif chunk_type == _CHUNK_BIN and not binary:
            binary = chunk

    if gltf is None:
        raise GLBError("GLB has no JSON chunk.")

    asset = gltf.get("asset") or {}
    if str(asset.get("version", "")) != "2.0":
        raise GLBError("glTF asset version must be 2.0.")

    if not (gltf.get("meshes") or gltf.get("scenes")):
        raise GLBError("GLB contains no meshes or scenes.")

    return gltf, binary


def build_glb(gltf: dict[str, Any], binary: bytes) -> bytes:
    json_bytes = _pad4(
        json.dumps(gltf, separators=(",", ":")).encode("utf-8"), b" "
    )
    chunks = struct.pack("<II", len(json_bytes), _CHUNK_JSON) + json_bytes

    if binary:
        bin_bytes = _pad4(binary, b"\x00")
        chunks += struct.pack("<II", len(bin_bytes), _CHUNK_BIN) + bin_bytes

    header = struct.pack("<III", _GLB_MAGIC, 2, 12 + len(chunks))
    return header + chunks


def _shrink_image(raw: bytes, max_size: int) -> tuple[bytes, str] | None:
    """Return (new_bytes, mime) if the image needed shrinking, else None."""
    with Image.open(io.BytesIO(raw)) as img:
        img.load()
        width, height = img.size

        if max(width, height) <= max_size:
            return None

        scale = max_size / float(max(width, height))
        new_size = (max(1, round(width * scale)), max(1, round(height * scale)))

        has_alpha = img.mode in ("RGBA", "LA") or (
            img.mode == "P" and "transparency" in img.info
        )

        resized = img.convert("RGBA" if has_alpha else "RGB").resize(
            new_size, Image.LANCZOS
        )

        out = io.BytesIO()
        if has_alpha:
            resized.save(out, format="PNG", optimize=True)
            mime = "image/png"
        else:
            resized.save(out, format="JPEG", quality=88, optimize=True)
            mime = "image/jpeg"

        return out.getvalue(), mime


def optimize_glb(
    content: bytes,
    max_texture_size: int = MAX_TEXTURE_SIZE,
) -> tuple[bytes, dict[str, Any]]:
    """
    Downscale embedded textures to ``max_texture_size``.

    Returns (glb_bytes, stats). On any problem the original bytes are returned
    with ``stats["optimized"] = False``.
    """
    stats: dict[str, Any] = {
        "optimized": False,
        "original_bytes": len(content),
        "final_bytes": len(content),
        "textures_total": 0,
        "textures_resized": 0,
        "max_texture_size": max_texture_size,
    }

    try:
        gltf, binary = parse_glb(content)

        images = gltf.get("images") or []
        buffer_views = gltf.get("bufferViews") or []
        stats["textures_total"] = len(images)

        if not images or not buffer_views or not binary:
            return content, stats

        replacements: dict[int, bytes] = {}

        for image in images:
            view_index = image.get("bufferView")
            if view_index is None or view_index in replacements:
                continue

            view = buffer_views[view_index]
            start = int(view.get("byteOffset", 0))
            end = start + int(view["byteLength"])
            raw = binary[start:end]

            try:
                shrunk = _shrink_image(raw, max_texture_size)
            except Exception:  # noqa: BLE001 - KTX2/WebP edge cases
                logger.info("Skipping texture bufferView=%s", view_index)
                continue

            if shrunk is None:
                continue

            new_bytes, mime = shrunk

            if len(new_bytes) >= len(raw) and mime == image.get("mimeType"):
                continue

            replacements[view_index] = new_bytes
            image["mimeType"] = mime

        # Any image sharing a replaced bufferView must use the new mime type.
        for image in images:
            view_index = image.get("bufferView")
            if view_index in replacements:
                new_bytes = replacements[view_index]
                image["mimeType"] = (
                    "image/png" if new_bytes[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
                )

        if not replacements:
            return content, stats

        new_binary = bytearray()
        for index, view in enumerate(buffer_views):
            if int(view.get("buffer", 0)) != 0:
                continue

            if index in replacements:
                data = replacements[index]
            else:
                start = int(view.get("byteOffset", 0))
                data = binary[start: start + int(view["byteLength"])]

            while len(new_binary) % 4:
                new_binary.append(0)

            view["byteOffset"] = len(new_binary)
            view["byteLength"] = len(data)
            new_binary.extend(data)

        buffers = gltf.get("buffers") or []
        if buffers:
            buffers[0]["byteLength"] = len(new_binary)
            buffers[0].pop("uri", None)

        optimized = build_glb(gltf, bytes(new_binary))

        if len(optimized) >= len(content):
            return content, stats

        stats.update(
            optimized=True,
            final_bytes=len(optimized),
            textures_resized=len(replacements),
        )
        return optimized, stats

    except GLBError:
        raise
    except Exception:  # noqa: BLE001
        logger.exception("GLB optimization failed; using original file.")
        return content, stats
