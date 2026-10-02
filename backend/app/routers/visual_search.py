import logging
import os
import urllib.request

from fastapi import APIRouter, UploadFile, File, HTTPException
from starlette.concurrency import run_in_threadpool
from supabase import create_client, Client

from app.vector_service import (
    generate_image_vector,
)


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Maximum uploaded/search image size: 8 MB.
MAX_IMAGE_BYTES = int(
    os.getenv(
        "VISUAL_MAX_UPLOAD_BYTES",
        str(8 * 1024 * 1024),
    )
)

# Maximum downloaded product image size during inventory indexing: 8 MB.
MAX_INDEX_IMAGE_BYTES = int(
    os.getenv(
        "VISUAL_MAX_INDEX_IMAGE_BYTES",
        str(8 * 1024 * 1024),
    )
)

# Prevent the indexer from hanging indefinitely on a dead image URL.
IMAGE_DOWNLOAD_TIMEOUT = int(
    os.getenv(
        "VISUAL_IMAGE_DOWNLOAD_TIMEOUT",
        "15",
    )
)


# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------

router = APIRouter(
    prefix="/api/search",
    tags=["Visual Search"],
)


# ---------------------------------------------------------------------------
# Supabase
# ---------------------------------------------------------------------------

supabase_url: str | None = os.getenv("SUPABASE_URL")

supabase_key: str | None = (
    os.getenv("SUPABASE_KEY")
    or os.getenv("SUPABASE_SERVICE_KEY")
)

if not supabase_url or not supabase_key:
    raise ValueError(
        "Supabase URL or Key is missing from environment variables."
    )

supabase: Client = create_client(
    supabase_url,
    supabase_key,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _read_limited_upload(
    file: UploadFile,
    max_bytes: int,
) -> bytes:
    """
    This helper is intentionally synchronous.

    It is executed through run_in_threadpool() from async routes,
    so blocking file I/O does not block FastAPI's main event loop.
    """

    import asyncio

    async def _read() -> bytes:
        data = await file.read(max_bytes + 1)

        if len(data) > max_bytes:
            raise ValueError(
                f"Image exceeds the {max_bytes // (1024 * 1024)} MB limit."
            )

        return data

    return asyncio.run(_read())


def _download_remote_image(
    image_url: str,
    max_bytes: int,
) -> bytes:
    """
    Download an image from a product URL while enforcing a hard
    memory limit.

    Used only by the inventory indexing endpoint.
    """

    request = urllib.request.Request(
        image_url,
        headers={
            "User-Agent": "PenguinStore-VisualIndexer/1.0"
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=IMAGE_DOWNLOAD_TIMEOUT,
    ) as response:

        # Content-Length is only an early check.
        # We still enforce the real limit while reading.
        content_length = response.headers.get("Content-Length")

        if content_length:
            try:
                if int(content_length) > max_bytes:
                    raise ValueError(
                        "Remote image exceeds the configured size limit."
                    )
            except ValueError as exc:
                if "exceeds" in str(exc):
                    raise

        chunks: list[bytes] = []
        total = 0

        while True:
            chunk = response.read(
                min(64 * 1024, max_bytes - total + 1)
            )

            if not chunk:
                break

            chunks.append(chunk)
            total += len(chunk)

            if total > max_bytes:
                raise ValueError(
                    "Remote image exceeds the configured size limit."
                )

        return b"".join(chunks)


# ---------------------------------------------------------------------------
# Visual Search
# ---------------------------------------------------------------------------

@router.post("/visual")
async def visual_product_search(
    file: UploadFile = File(...),
):
    """
    Accept an uploaded image, generate its 2048-D image embedding,
    query Supabase pgvector, and return matching products.

    Existing Flutter response structure is preserved.
    """

    try:
        # ---------------------------------------------------------------
        # 1. Basic content-type check
        # ---------------------------------------------------------------

        if file.content_type:
            if not file.content_type.startswith("image/"):
                raise HTTPException(
                    status_code=415,
                    detail="Please upload a valid image file.",
                )

        # ---------------------------------------------------------------
        # 2. Read upload with hard size limit
        # ---------------------------------------------------------------

        image_bytes = await file.read(
            MAX_IMAGE_BYTES + 1
        )

        if len(image_bytes) > MAX_IMAGE_BYTES:
            raise HTTPException(
                status_code=413,
                detail=(
                    f"Image is too large. Maximum allowed size is "
                    f"{MAX_IMAGE_BYTES // (1024 * 1024)} MB."
                ),
            )

        if not image_bytes:
            raise HTTPException(
                status_code=400,
                detail="Uploaded image is empty.",
            )

        # ---------------------------------------------------------------
        # 3. Generate 2048-D image vector
        # ---------------------------------------------------------------
        #
        # FastEmbed inference is synchronous CPU work.
        # Run it outside FastAPI's async event loop.
        #

        try:
            query_vector = await run_in_threadpool(
                generate_image_vector,
                image_bytes,
            )

        except ValueError as exc:
            raise HTTPException(
                status_code=400,
                detail=str(exc),
            ) from exc

        except RuntimeError as exc:
            logger.exception(
                "Image vector generation failed: %s",
                exc,
            )

            raise HTTPException(
                status_code=503,
                detail=(
                    "Visual search is temporarily unavailable."
                ),
            ) from exc

        # ---------------------------------------------------------------
        # 4. Final vector validation
        # ---------------------------------------------------------------

        if len(query_vector) != 2048:
            logger.error(
                "Invalid image vector dimension: %d",
                len(query_vector),
            )

            raise HTTPException(
                status_code=503,
                detail=(
                    "Visual search returned an invalid embedding."
                ),
            )

        # ---------------------------------------------------------------
        # 5. Supabase vector similarity search
        # ---------------------------------------------------------------

        try:
            response = supabase.rpc(
                "match_products_v2",
                {
                    "query_embedding": query_vector,
                    "match_limit": 6,
                },
            ).execute()

        except Exception as exc:
            logger.exception(
                "Supabase visual search RPC failed: %s",
                exc,
            )

            raise HTTPException(
                status_code=503,
                detail=(
                    "Product search is temporarily unavailable."
                ),
            ) from exc

        # ---------------------------------------------------------------
        # 6. Preserve existing Flutter response format
        # ---------------------------------------------------------------

        scored_products = []

        for match in response.data or []:
            scored_products.append(
                {
                    "score": float(match.get("score", 0.0)),
                    "product": match.get("product", {}),
                }
            )

        return {
            "query_status": "success",
            "total_matches": len(scored_products),
            "matches": scored_products,
        }

    except HTTPException:
        raise

    except Exception as exc:
        logger.exception(
            "Unexpected visual search error: %s",
            exc,
        )

        raise HTTPException(
            status_code=500,
            detail="Failed to process visual search.",
        ) from exc


# ---------------------------------------------------------------------------
# Inventory Indexing
# ---------------------------------------------------------------------------

@router.post("/index-inventory")
def index_existing_products():
    """
    Find products without a 2048-D image embedding, download their
    images, generate embeddings, and save them to image_embedding_v2.
    """

    # ---------------------------------------------------------------
    # 1. Fetch products without v2 embeddings
    # ---------------------------------------------------------------

    try:
        response = (
            supabase
            .table("products")
            .select("id,name,image_url")
            .is_("image_embedding_v2", "null")
            .execute()
        )

        products = response.data or []

    except Exception as exc:
        logger.exception(
            "Failed to fetch products for visual indexing: %s",
            exc,
        )

        raise HTTPException(
            status_code=503,
            detail="Unable to load products for indexing.",
        ) from exc

    indexed_count = 0
    skipped_count = 0

    # ---------------------------------------------------------------
    # 2. Process products one-by-one
    # ---------------------------------------------------------------

    for product in products:

        product_id = product.get("id")
        product_name = product.get("name", "Unknown product")
        image_url = product.get("image_url")

        if not image_url:
            skipped_count += 1
            continue

        try:

            # -------------------------------------------------------
            # Download image safely
            # -------------------------------------------------------

            image_bytes = _download_remote_image(
                image_url,
                MAX_INDEX_IMAGE_BYTES,
            )

            if not image_bytes:
                raise ValueError(
                    "Downloaded image is empty."
                )

            # -------------------------------------------------------
            # Generate 2048-D image vector
            # -------------------------------------------------------

            vector = generate_image_vector(
                image_bytes
            )

            # -------------------------------------------------------
            # Store vector in PostgreSQL pgvector column
            # -------------------------------------------------------

            (
                supabase
                .table("products")
                .update(
                    {
                        "image_embedding_v2": vector,
                    }
                )
                .eq("id", product_id)
                .execute()
            )

            indexed_count += 1

            logger.info(
                "Indexed product: %s (%s)",
                product_name,
                product_id,
            )

        except Exception as exc:
            skipped_count += 1

            logger.exception(
                "[INDEXING ERROR] Product %s (%s): %s",
                product_name,
                product_id,
                exc,
            )

            continue

    # ---------------------------------------------------------------
    # 3. Summary
    # ---------------------------------------------------------------

    return {
        "message": (
            f"Successfully generated visual embeddings for "
            f"{indexed_count} products."
        ),
        "indexed_count": indexed_count,
        "skipped_count": skipped_count,
        "total_candidates": len(products),
    }