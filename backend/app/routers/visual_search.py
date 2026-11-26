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
        from app.core.supabase_rest import (
            get_supabase_client,
            is_pg_tcp_reachable,
            mark_pg_tcp_unreachable,
        )

        rows_data: list[dict[str, Any]] = []
        if is_pg_tcp_reachable():
            try:
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
                rows_data = [dict(row._mapping) for row in rows]
            except Exception as exc:
                logger.warning("Visual catalog TCP query failed, falling back to HTTPS: %s", exc)
                mark_pg_tcp_unreachable()

        if not rows_data:
            try:
                client = get_supabase_client()
                res = (
                    client.table("products")
                    .select(
                        "id,name,description,price,original_price,image_url,category,"
                        "rating,reviews,discount_percent,is_featured,stock,fulfillment_type,"
                        "image_embedding_v2"
                    )
                    .not_.is_("image_embedding_v2", "null")
                    .order("id")
                    .execute()
                )
                for r in res.data or []:
                    if isinstance(r, dict):
                        m = dict(r)
                        m["emb_text"] = m.get("image_embedding_v2")
                        rows_data.append(m)
            except Exception as exc:
                logger.warning("Visual catalog HTTPS vector load failed: %s", exc)

        from app.core.supabase_rest import is_product_active_row

        products: list[dict[str, Any]] = []
        vectors: list[np.ndarray] = []

        for mapping in rows_data:
            if not is_product_active_row(mapping):
                continue
            emb_val = mapping.get("emb_text")
            if not emb_val:
                continue

            if isinstance(emb_val, list):
                vec = np.asarray(emb_val, dtype=np.float32)
            else:
                vec = np.fromstring(
                    str(emb_val).strip("[]"),
                    sep=",",
                    dtype=np.float32,
                )
            if vec.shape[0] != 2048:
                continue

            norm = float(np.linalg.norm(vec))
            if norm <= 1e-12:
                continue
            vec = vec / norm

            products.append(_sanitize_public_product(mapping))
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


def classify_visual_confidence(score: float) -> tuple[str, str]:
    """
    Map a calibrated cosine similarity score into industry-honest confidence tiers:
      - >= 0.75 : ('strong_match', 'Strong Match')
      - 0.55..0.74 : ('similar_style', 'Similar Style')
      - < 0.55 : ('closest_alternatives', 'Closest Alternative')
    """
    s = float(score)
    if s >= 0.75:
        return "strong_match", ("Exact Match" if s >= 0.88 else "Strong Match")
    if s >= 0.55:
        return "similar_style", "Similar Style"
    return "closest_alternatives", "Closest Alternative"


def build_visual_search_summary(
    *,
    confidence_tier: str,
    match_count: int,
    is_blank_or_noise: bool = False,
    has_text_refinement: bool = False,
) -> str:
    if is_blank_or_noise:
        return (
            "The uploaded image appears blank or lacks recognizable visual detail. "
            "Please upload a clearer photo of the item."
        )
    if match_count == 0:
        return (
            "No in-stock products matched all visual and filter constraints. "
            "Try relaxing your price filter or refining with text below."
        )
    if confidence_tier == "strong_match":
        return (
            f"Found {match_count} high-confidence visual match{'es' if match_count != 1 else ''} "
            "in the Penguin Store catalog."
        )
    if confidence_tier == "similar_style":
        return (
            f"Found {match_count} visually similar style{'s' if match_count != 1 else ''} "
            "currently in stock. Refine with text or voice below to narrow further."
        )
    return (
        "We couldn't find an exact visual match for this item, so here are the "
        "closest styles currently in stock—or refine with a text filter below."
    )


def _calibrate_display_score(
    raw_score: float,
    was_deblurred: bool,
    is_heavily_blurred: bool,
) -> float:
    """
    Calibrate raw ResNet-50 cosine similarity into an honest user-facing
    confidence score in [0.0, 0.995]. Weak matches (<0.42) are NEVER inflated
    into fake high percentages.
    """
    score = float(raw_score)
    if was_deblurred and score >= 0.42:
        boost = 0.08 if is_heavily_blurred else 0.05
        score = min(0.995, score + boost * (1.0 - score * 0.5))
    return round(float(max(0.0, min(0.995, score))), 4)


def _format_visual_match_reason(
    *,
    display_score: float,
    match_label: str,
    product: dict[str, Any],
) -> str:
    pct = int(round(display_score * 100))
    cat = str(product.get("category") or "").strip()
    stock = int(product.get("stock") if product.get("stock") is not None else 50)
    parts = [f"{pct}% {match_label}"]
    if cat:
        parts.append(cat.title())
    parts.append(f"Only {stock} Left" if 0 < stock <= 5 else "In Stock")
    return " • ".join(parts)


def _rank_and_filter_matches(
    embed_result: dict[str, Any],
    limit: int = 6,
) -> list[dict[str, Any]]:
    """
    Rank indexed in-stock catalog products against query variants and classify into
    calibrated confidence tiers (`Strong Match`, `Similar Style`, or `Closest Alternative`)
    while rejecting blank/noise images cleanly.
    """
    if embed_result.get("is_blank_or_noise"):
        return []

    is_heavily_blurred = bool(embed_result.get("is_heavily_blurred"))
    was_deblurred = bool(embed_result.get("was_deblurred"))

    products, matrix = _catalog_cache.get_catalog()

    if matrix is not None and len(products) == matrix.shape[0] and len(products) > 0:
        variant_vectors = embed_result.get("variant_vectors") or []
        variant_weights = embed_result.get("variant_weights") or []
        primary_vec = np.asarray(
            embed_result["primary_vector"],
            dtype=np.float32,
        )

        best_scores = matrix @ primary_vec

        for vec_list, weight in zip(variant_vectors, variant_weights):
            v_arr = np.asarray(vec_list, dtype=np.float32)
            penalty = 1.0 if weight >= 0.96 else float(weight)
            variant_scores = (matrix @ v_arr) * penalty
            best_scores = np.maximum(best_scores, variant_scores)

        sorted_indices = np.argsort(best_scores)[::-1]
        in_stock_indices = [
            int(idx)
            for idx in sorted_indices
            if int(products[int(idx)].get("stock") if products[int(idx)].get("stock") is not None else 50) > 0
        ]
        if not in_stock_indices:
            in_stock_indices = [int(i) for i in sorted_indices]

        top_index = in_stock_indices[0]
        top_raw_score = float(best_scores[top_index])
        top_display = _calibrate_display_score(
            top_raw_score,
            was_deblurred=was_deblurred,
            is_heavily_blurred=is_heavily_blurred,
        )
        top_tier, _ = classify_visual_confidence(top_display)
        top_product = products[top_index]
        top_family = _category_family(top_product.get("category"))

        results: list[dict[str, Any]] = []
        relative_floor = max(0.32, top_raw_score - 0.35)

        for idx in in_stock_indices:
            raw_s = float(best_scores[idx])
            prod = products[idx]
            prod_family = _category_family(prod.get("category"))

            if top_tier in ("strong_match", "similar_style"):
                if prod_family == top_family:
                    if raw_s < relative_floor:
                        continue
                else:
                    if raw_s < 0.62 or (top_raw_score - raw_s) > 0.04:
                        continue

            display_score = _calibrate_display_score(
                raw_s,
                was_deblurred=was_deblurred,
                is_heavily_blurred=is_heavily_blurred,
            )
            tier, match_label = classify_visual_confidence(display_score)
            match_reason = _format_visual_match_reason(
                display_score=display_score,
                match_label=match_label,
                product=prod,
            )

            results.append(
                {
                    "score": display_score,
                    "raw_score": round(raw_s, 4),
                    "confidence_tier": tier,
                    "match_label": match_label,
                    "match_reason": match_reason,
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

    scored_products: list[dict[str, Any]] = []
    for match in raw_matches:
        raw_s = float(match.get("score", 0.0))
        prod = _sanitize_public_product(match.get("product") or {})
        display_score = _calibrate_display_score(
            raw_s,
            was_deblurred=was_deblurred,
            is_heavily_blurred=is_heavily_blurred,
        )
        tier, match_label = classify_visual_confidence(display_score)
        scored_products.append(
            {
                "score": display_score,
                "raw_score": round(raw_s, 4),
                "confidence_tier": tier,
                "match_label": match_label,
                "match_reason": _format_visual_match_reason(
                    display_score=display_score,
                    match_label=match_label,
                    product=prod,
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

        from app.core.upload_security import validate_image_upload
        import gc

        validate_image_upload(
            image_bytes,
            file.filename,
            max_bytes=MAX_IMAGE_BYTES,
            require_extension=False,
        )

        # 3. Analyze image quality, deblur if needed, and compute embeddings
        try:
            embed_result = await run_in_threadpool(
                analyze_and_embed_query,
                image_bytes,
            )
            gc.collect()

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
        is_blank = bool(embed_result.get("is_blank_or_noise", False))
        has_results = len(scored_products) > 0
        top1_sim = float(scored_products[0]["score"]) if has_results else 0.0
        confidence_tier = (
            scored_products[0]["confidence_tier"]
            if has_results
            else ("blank_or_noise" if is_blank else "none")
        )
        # Exact/Strong or Similar Style counts as direct visual match; Closest Alternatives are honest fallbacks
        in_database = has_results
        search_summary = build_visual_search_summary(
            confidence_tier=confidence_tier,
            match_count=len(scored_products),
            is_blank_or_noise=is_blank,
        )
        detected_category = (
            scored_products[0]["product"].get("category")
            if has_results
            else None
        )

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
                "closest_alternatives"
                if confidence_tier == "closest_alternatives"
                else ("success" if has_results else "not_in_database")
            ),
            "in_database": in_database,
            "confidence_tier": confidence_tier,
            "search_summary": search_summary,
            "message": search_summary,
            "total_matches": len(scored_products),
            "matches": scored_products,
            "analysis": {
                "confidence_tier": confidence_tier,
                "search_summary": search_summary,
                "sharpness_score": embed_result.get("sharpness_score"),
                "is_blurry": embed_result.get("is_blurry", False),
                "was_deblurred": embed_result.get("was_deblurred", False),
                "is_blank_or_noise": is_blank,
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
