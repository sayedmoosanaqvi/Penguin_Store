import logging
import os
import time
import urllib.request
from pathlib import Path
from threading import Lock
from typing import Any
from urllib.parse import urlsplit

import numpy as np
from dotenv import load_dotenv
from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
    status,
)
from sqlalchemy import text
from starlette.concurrency import run_in_threadpool
from supabase import Client, create_client

from app.core.config import settings
from app.database import SessionLocal, engine
from app.models import Product, User
from app.security import (
    AGENT_API_KEY,
    get_optional_current_user,
    resolve_user_role,
)
from app.vector_service import (
    analyze_and_embed_query,
    generate_image_vector,
)
from app.services.ai_telemetry_service import record_visual_search_metric

_BACKEND_ENV_PATH = Path(__file__).resolve().parents[2] / ".env"
load_dotenv(_BACKEND_ENV_PATH)
load_dotenv()

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

# Similarity thresholds for determining if a product exists in the database.
MIN_SHARP_MATCH_SCORE = float(
    os.getenv("VISUAL_MIN_SHARP_SCORE", "0.46")
)
MIN_BLUR_MATCH_SCORE = float(
    os.getenv("VISUAL_MIN_BLUR_SCORE", "0.435")
)

ALLOWED_PROXY_HOSTS = {
    "cdn.dummyjson.com",
    "bjfspmjpiagfqildttjd.supabase.co",
    "penguin-store-assets-v1.s3.eu-north-1.amazonaws.com",
    "images.unsplash.com",
    "tse2.mm.bing.net",
    "tse3.mm.bing.net",
    "down-sg.img.susercontent.com",
}


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
    os.getenv("SUPABASE_SERVICE_KEY")
    or os.getenv("SUPABASE_KEY")
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
# Category Family Mapping & Sanitization
# ---------------------------------------------------------------------------

_CATEGORY_FAMILIES: dict[str, str] = {
    "TEE SHIRTS": "apparel_tops",
    "MENS-SHIRTS": "apparel_tops",
    "SHIRTS": "apparel_tops",
    "TOPS": "apparel_tops",
    "WOMENS-DRESSES": "apparel_tops",
    "PANTS": "apparel_bottoms",
    "MENS-SHOES": "footwear",
    "MEN SHOES": "footwear",
    "WOMENS-SHOES": "footwear",
    "SHOES": "footwear",
    "MENS-WATCHES": "watches_accessories",
    "WOMENS-WATCHES": "watches_accessories",
    "WOMEN ACCESSORIES": "watches_accessories",
    "WOMENS-BAGS": "watches_accessories",
    "ACCESSORIES": "watches_accessories",
    "SUNGLASSES": "watches_accessories",
    "SMARTPHONES": "electronics_tech",
    "SMARTPHONE": "electronics_tech",
    "MOBILE-ACCESSORIES": "electronics_tech",
    "MOBILE ACCESSORIES": "electronics_tech",
    "LAPTOPS": "electronics_tech",
    "TABLETS": "electronics_tech",
    "ELECTRONICS": "electronics_tech",
    "BEAUTY": "beauty_care",
    "FRAGRANCES": "beauty_care",
    "SKIN-CARE": "beauty_care",
    "WOMEN": "beauty_care",
    "KITCHEN-ACCESSORIES": "home_living",
    "HOME-DECORATION": "home_living",
    "FURNITURE": "home_living",
    "GROCERIES": "groceries_food",
    "FOOD": "groceries_food",
    "MOTORCYCLE": "automotive",
    "VEHICLE": "automotive",
    "WHEELS": "automotive",
}


def _category_family(category: str | None) -> str:
    if not category:
        return "other"
    norm = category.strip().upper()
    if norm in _CATEGORY_FAMILIES:
        return _CATEGORY_FAMILIES[norm]
    if "SHIRT" in norm or "DRESS" in norm or "TOP" in norm:
        return "apparel_tops"
    if "SHOE" in norm or "BOOT" in norm or "SNEAKER" in norm:
        return "footwear"
    if "WATCH" in norm or "BAG" in norm:
        return "watches_accessories"
    if "PHONE" in norm or "LAPTOP" in norm or "ELECTRONIC" in norm or "MOBILE" in norm:
        return "electronics_tech"
    if "BEAUTY" in norm or "FRAGRANCE" in norm or "SKIN" in norm or "PERFUME" in norm:
        return "beauty_care"
    if "KITCHEN" in norm or "HOME" in norm or "FURNITURE" in norm:
        return "home_living"
    if "GROCER" in norm or "FOOD" in norm:
        return "groceries_food"
    return norm


def _sanitize_public_product(raw: dict[str, Any]) -> dict[str, Any]:
    """
    Ensure only customer-safe product fields are returned to the frontend.
    Strips internal supplier_id, supplier_sku, cost_price, and vector fields.
    """
    return {
        "id": int(raw.get("id") or 0),
        "name": str(raw.get("name") or ""),
        "description": raw.get("description") or "",
        "price": float(raw.get("price") or 0.0),
        "original_price": (
            float(raw["original_price"])
            if raw.get("original_price") is not None
            else None
        ),
        "image_url": str(raw.get("image_url") or "").strip(),
        "category": str(raw.get("category") or ""),
        "rating": float(raw.get("rating") or 0.0),
        "reviews": int(raw.get("reviews") or 0),
        "discount_percent": (
            int(raw["discount_percent"])
            if raw.get("discount_percent") is not None
            else None
        ),
        "is_featured": bool(raw.get("is_featured", False)),
        "stock": int(raw.get("stock") if raw.get("stock") is not None else 50),
        "fulfillment_type": str(raw.get("fulfillment_type") or "IN_HOUSE"),
    }


# ---------------------------------------------------------------------------
# Fast In-Memory Catalog Vector Cache
# ---------------------------------------------------------------------------

class _VisualCatalogCache:
    def __init__(self) -> None:
        self._lock = Lock()
        self._loaded_at: float = 0.0
        self._products: list[dict[str, Any]] = []
        self._matrix: np.ndarray | None = None
        self._ttl_seconds: float = 180.0

    def invalidate(self) -> None:
        with self._lock:
            self._loaded_at = 0.0
            self._products = []
            self._matrix = None

    def _load_from_db(self) -> tuple[list[dict[str, Any]], np.ndarray | None]:
        with engine.connect() as conn:
            rows = conn.execute(
                text(
                    """
                    SELECT
                        id,
                        name,
                        description,
                        price,
                        original_price,
                        image_url,
                        category,
                        rating,
                        reviews,
                        discount_percent,
                        is_featured,
                        stock,
                        fulfillment_type,
                        image_embedding_v2::text AS emb_text
                    FROM products
                    WHERE image_embedding_v2 IS NOT NULL
                    ORDER BY id ASC
                    """
                )
            ).fetchall()

        products: list[dict[str, Any]] = []
        vectors: list[np.ndarray] = []

        for row in rows:
            mapping = row._mapping
            emb_text = mapping.get("emb_text")
            if not emb_text:
                continue

            vec = np.fromstring(
                emb_text.strip("[]"),
                sep=",",
                dtype=np.float32,
            )
            if vec.shape[0] != 2048:
                continue

            norm = float(np.linalg.norm(vec))
            if norm <= 1e-12:
                continue
            vec = vec / norm

            products.append(_sanitize_public_product(dict(mapping)))
            vectors.append(vec)

        if not vectors:
            return [], None

        matrix = np.vstack(vectors)
        return products, matrix

    def get_catalog(self) -> tuple[list[dict[str, Any]], np.ndarray | None]:
        now = time.monotonic()
        if (
            self._matrix is not None
            and self._products
            and (now - self._loaded_at) < self._ttl_seconds
        ):
            return self._products, self._matrix

        with self._lock:
            now = time.monotonic()
            if (
                self._matrix is not None
                and self._products
                and (now - self._loaded_at) < self._ttl_seconds
            ):
                return self._products, self._matrix

            products, matrix = self._load_from_db()
            self._products = products
            self._matrix = matrix
            self._loaded_at = time.monotonic()
            return self._products, self._matrix


_catalog_cache = _VisualCatalogCache()


def invalidate_visual_cache() -> None:
    _catalog_cache.invalidate()


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
    """

    request = urllib.request.Request(
        image_url,
        headers={
            "User-Agent": "Mozilla/5.0 (compatible; PenguinStore-VisualIndexer/2.0)"
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=IMAGE_DOWNLOAD_TIMEOUT,
    ) as response:

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


def _sniff_image_media_type(data: bytes, fallback: str = "image/jpeg") -> str:
    if len(data) >= 3 and data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if len(data) >= 8 and data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    if len(data) >= 6 and data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if len(data) >= 12 and b"ftypavif" in data[:16]:
        return "image/avif"
    if fallback and fallback.startswith("image/"):
        return fallback.split(";")[0].strip()
    return "image/jpeg"


def _calibrate_display_score(
    raw_score: float,
    was_deblurred: bool,
    is_heavily_blurred: bool,
) -> float:
    """
    Calibrate raw ResNet-50 cosine similarity into an intuitive user-facing
    confidence score in [0.0, 0.999], accounting for high-frequency attenuation
    on blurred user photos while preserving strict ranking order.
    """
    score = float(raw_score)
    if was_deblurred:
        boost = 0.14 if is_heavily_blurred else 0.08
        score = min(0.995, score + boost * (1.0 - score * 0.5))
    return round(float(max(0.0, min(0.999, score))), 4)


def _rank_and_filter_matches(
    embed_result: dict[str, Any],
    limit: int = 6,
) -> list[dict[str, Any]]:
    """
    Rank all indexed catalog products against the query variants, apply
    strict database presence thresholds, and enforce category coherence.
    """
    if embed_result.get("is_blank_or_noise"):
        return []

    is_blurry = bool(embed_result.get("is_blurry"))
    is_heavily_blurred = bool(embed_result.get("is_heavily_blurred"))
    was_deblurred = bool(embed_result.get("was_deblurred"))

    min_threshold = (
        MIN_BLUR_MATCH_SCORE
        if is_blurry
        else MIN_SHARP_MATCH_SCORE
    )

    products, matrix = _catalog_cache.get_catalog()

    if matrix is not None and len(products) == matrix.shape[0] and len(products) > 0:
        variant_vectors = embed_result.get("variant_vectors") or []
        variant_weights = embed_result.get("variant_weights") or []
        primary_vec = np.asarray(
            embed_result["primary_vector"],
            dtype=np.float32,
        )

        # Score against ensemble vector
        best_scores = matrix @ primary_vec

        # Also score against each individual query variant (original, deblurred, center-crop)
        for vec_list, weight in zip(variant_vectors, variant_weights):
            v_arr = np.asarray(vec_list, dtype=np.float32)
            # Apply slight discount only to cropped variant so full-image exact match wins ties
            penalty = 1.0 if weight >= 0.96 else float(weight)
            variant_scores = (matrix @ v_arr) * penalty
            best_scores = np.maximum(best_scores, variant_scores)

        top_index = int(np.argmax(best_scores))
        top_raw_score = float(best_scores[top_index])

        # Check if the top product is genuinely in the database!
        if top_raw_score < min_threshold:
            return []

        # Also check margin between #1 and median catalog score to reject flat ambiguous noise
        median_score = float(np.median(best_scores))
        if (top_raw_score - median_score) < 0.11 and top_raw_score < 0.54:
            return []

        top_product = products[top_index]
        top_family = _category_family(top_product.get("category"))

        # Sort candidates descending
        sorted_indices = np.argsort(best_scores)[::-1]

        results: list[dict[str, Any]] = []
        relative_floor = max(
            min_threshold - 0.02,
            top_raw_score - 0.40,
        )

        for idx in sorted_indices:
            raw_s = float(best_scores[int(idx)])
            prod = products[int(idx)]
            prod_family = _category_family(prod.get("category"))

            if prod_family == top_family:
                if raw_s < max(min_threshold - 0.03, relative_floor):
                    continue
            else:
                # Filter out unrelated category noise unless similarity is very high
                if raw_s < 0.65 or (top_raw_score - raw_s) > 0.035:
                    continue

            display_score = _calibrate_display_score(
                raw_s,
                was_deblurred=was_deblurred,
                is_heavily_blurred=is_heavily_blurred,
            )

            match_label = (
                "Exact Match"
                if display_score >= 0.85
                else (
                    "Strong Match"
                    if display_score >= 0.65
                    else "Visual Match"
                )
            )

            results.append(
                {
                    "score": display_score,
                    "raw_score": round(raw_s, 4),
                    "match_label": match_label,
                    "product": prod,
                }
            )

            if len(results) >= limit:
                break

        return results

    # Fallback to Supabase RPC if direct DB matrix was empty
    query_vector = embed_result["primary_vector"]
    response = supabase.rpc(
        "match_products_v2",
        {
            "query_embedding": query_vector,
            "match_limit": limit,
        },
    ).execute()

    raw_matches = response.data or []
    if not raw_matches:
        return []

    top_raw_score = float(raw_matches[0].get("score", 0.0))
    if top_raw_score < min_threshold:
        return []

    top_prod = _sanitize_public_product(raw_matches[0].get("product") or {})
    top_family = _category_family(top_prod.get("category"))

    scored_products: list[dict[str, Any]] = []
    for match in raw_matches:
        raw_s = float(match.get("score", 0.0))
        if raw_s < min_threshold - 0.02:
            continue
        prod = _sanitize_public_product(match.get("product") or {})
        prod_family = _category_family(prod.get("category"))
        if prod_family != top_family and raw_s < 0.65:
            continue

        display_score = _calibrate_display_score(
            raw_s,
            was_deblurred=was_deblurred,
            is_heavily_blurred=is_heavily_blurred,
        )
        scored_products.append(
            {
                "score": display_score,
                "raw_score": round(raw_s, 4),
                "match_label": (
                    "Exact Match"
                    if display_score >= 0.85
                    else "Visual Match"
                ),
                "product": prod,
            }
        )

    return scored_products


def index_single_product_by_id(product_id: int) -> bool:
    """
    Download a single product's image, compute its 2048-D ResNet-50 embedding,
    save it to PostgreSQL, and refresh the in-memory visual search cache.
    Safe to run in FastAPI BackgroundTasks.
    """
    db = SessionLocal()
    try:
        row = (
            db.query(Product.id, Product.name, Product.image_url)
            .filter(Product.id == product_id)
            .first()
        )
        if not row or not row.image_url:
            return False

        image_bytes = _download_remote_image(
            row.image_url,
            MAX_INDEX_IMAGE_BYTES,
        )
        if not image_bytes:
            return False

        vector = generate_image_vector(image_bytes)
        (
            db.query(Product)
            .filter(Product.id == product_id)
            .update({"image_embedding_v2": vector})
        )
        db.commit()
        invalidate_visual_cache()
        logger.info(
            "Auto-indexed visual embedding for product %s (%s)",
            row.name,
            product_id,
        )
        return True
    except Exception as exc:
        db.rollback()
        logger.warning(
            "Background visual indexing failed for product %s: %s",
            product_id,
            exc,
        )
        return False
    finally:
        db.close()


# ---------------------------------------------------------------------------
# Visual Search Endpoint
# ---------------------------------------------------------------------------

@router.post("/visual")
async def visual_product_search(
    file: UploadFile = File(...),
):
    """
    Accept an uploaded image, automatically enhance/deblur if blurry,
    generate multi-variant 2048-D embeddings, and match against the
    Penguin Store catalog.

    If no product in the database meets the similarity threshold,
    returns query_status="not_in_database" and an empty matches list.
    """
    started_at = time.perf_counter()

    try:
        # 1. Basic content-type check
        if file.content_type:
            if not file.content_type.startswith("image/"):
                raise HTTPException(
                    status_code=415,
                    detail="Please upload a valid image file.",
                )

        # 2. Read upload with hard size limit
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

        # 3. Analyze image quality, deblur if needed, and compute embeddings
        try:
            embed_result = await run_in_threadpool(
                analyze_and_embed_query,
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

        # 4. Final vector validation
        primary_vector = embed_result.get("primary_vector") or []
        if len(primary_vector) != 2048:
            logger.error(
                "Invalid image vector dimension: %d",
                len(primary_vector),
            )

            raise HTTPException(
                status_code=503,
                detail=(
                    "Visual search returned an invalid embedding."
                ),
            )

        # 5. Fast catalog similarity search & threshold filtering
        try:
            scored_products = await run_in_threadpool(
                _rank_and_filter_matches,
                embed_result,
                6,
            )
        except Exception as exc:
            logger.exception(
                "Visual catalog search failed: %s",
                exc,
            )
            raise HTTPException(
                status_code=503,
                detail="Product search is temporarily unavailable.",
            ) from exc

        elapsed_ms = round((time.perf_counter() - started_at) * 1000, 1)
        in_database = len(scored_products) > 0
        detected_category = (
            scored_products[0]["product"].get("category")
            if in_database
            else None
        )

        top1_sim = float(scored_products[0]["score"]) if in_database else 0.0
        top5_slice = scored_products[:5]
        avg_top5_sim = (
            round(sum(float(m["score"]) for m in top5_slice) / len(top5_slice), 4)
            if top5_slice
            else 0.0
        )
        try:
            record_visual_search_metric(
                latency_ms=elapsed_ms,
                top1_similarity=top1_sim,
                avg_top5_similarity=avg_top5_sim,
                total_matches=len(scored_products),
                was_deblurred=bool(embed_result.get("was_deblurred", False)),
            )
        except Exception:
            pass

        return {
            "query_status": (
                "success" if in_database else "not_in_database"
            ),
            "in_database": in_database,
            "message": (
                f"Found {len(scored_products)} matching products in the database."
                if in_database
                else "This product is not in the Penguin Store database."
            ),
            "total_matches": len(scored_products),
            "matches": scored_products,
            "analysis": {
                "sharpness_score": embed_result.get("sharpness_score"),
                "is_blurry": embed_result.get("is_blurry", False),
                "was_deblurred": embed_result.get("was_deblurred", False),
                "detected_category": detected_category,
                "search_time_ms": elapsed_ms,
            },
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

    finally:
        await file.close()


# ---------------------------------------------------------------------------
# Safe Image Proxy (fixes S3 octet-stream & cross-origin image loading)
# ---------------------------------------------------------------------------

@router.get("/image-proxy")
async def proxy_product_image(
    request: Request,
    product_id: int | None = Query(default=None, ge=1),
    url: str | None = Query(default=None, max_length=1024),
):
    """
    Stream a catalog product's image with a verified image/* Content-Type
    header and CORS support so Flutter Web/Mobile never fails on legacy
    S3 application/octet-stream headers.
    """
    target_url: str | None = None

    if product_id is not None:
        def _lookup_url() -> str | None:
            db = SessionLocal()
            try:
                row = (
                    db.query(Product.image_url)
                    .filter(Product.id == product_id)
                    .first()
                )
                return row[0] if row else None
            finally:
                db.close()

        target_url = await run_in_threadpool(_lookup_url)

    if not target_url and url:
        parsed = urlsplit(url.strip())
        if (
            parsed.scheme in ("http", "https")
            and parsed.hostname in ALLOWED_PROXY_HOSTS
        ):
            target_url = url.strip()

    if not target_url:
        raise HTTPException(
            status_code=404,
            detail="Product image not found.",
        )

    try:
        image_bytes = await run_in_threadpool(
            _download_remote_image,
            target_url,
            MAX_INDEX_IMAGE_BYTES,
        )
    except Exception as exc:
        logger.warning("Image proxy failed for %s: %s", target_url, exc)
        raise HTTPException(
            status_code=502,
            detail="Unable to load product image.",
        ) from exc

    media_type = _sniff_image_media_type(image_bytes)
    origin = request.headers.get("origin", "").strip().rstrip("/")
    allowed = set(settings.allowed_origins)
    cors_header = (
        origin
        if origin in allowed or (not settings.IS_PRODUCTION and origin)
        else (settings.allowed_origins[0] if settings.allowed_origins else "https://penguin-store.github.io")
    )
    return Response(
        content=image_bytes,
        media_type=media_type,
        headers={
            "Cache-Control": "public, max-age=86400",
            "Access-Control-Allow-Origin": cors_header,
            "Vary": "Origin",
        },
    )


# ---------------------------------------------------------------------------
# Inventory Indexing
# ---------------------------------------------------------------------------

@router.post("/index-inventory")
def index_existing_products(
    request: Request,
    current_user: User | None = Depends(get_optional_current_user),
):
    """
    Find products without a 2048-D image embedding, download their
    images, generate embeddings, and save them to image_embedding_v2.
    Requires Admin JWT or X-Agent-Key (or local development loopback).
    """
    api_key = request.headers.get("X-Agent-Key", "").strip()
    is_local_dev = (
        os.getenv("ENVIRONMENT", "development").lower() == "development"
        and request.client is not None
        and request.client.host in ("127.0.0.1", "::1", "localhost")
    )
    has_agent_key = bool(api_key and api_key == AGENT_API_KEY)
    has_admin_jwt = bool(current_user and resolve_user_role(current_user) == "admin")

    if not (is_local_dev or has_agent_key or has_admin_jwt):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Administrator or agent credentials required to index inventory.",
        )

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

    for product in products:
        product_id = product.get("id")
        product_name = product.get("name", "Unknown product")
        image_url = product.get("image_url")

        if not image_url:
            skipped_count += 1
            continue

        try:
            image_bytes = _download_remote_image(
                image_url,
                MAX_INDEX_IMAGE_BYTES,
            )

            if not image_bytes:
                raise ValueError(
                    "Downloaded image is empty."
                )

            vector = generate_image_vector(
                image_bytes
            )

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

    invalidate_visual_cache()

    return {
        "message": (
            f"Successfully generated visual embeddings for "
            f"{indexed_count} products."
        ),
        "indexed_count": indexed_count,
        "skipped_count": skipped_count,
        "total_candidates": len(products),
    }
