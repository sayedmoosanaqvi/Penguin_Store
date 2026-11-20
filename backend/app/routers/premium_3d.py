
import logging
import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from threading import Lock
from urllib.parse import urlsplit

from fastapi import (
    APIRouter,
    Depends,
    File,
    Form,
    HTTPException,
    Request,
    Response,
    UploadFile,
    status,
)
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from supabase import create_client

import io
import time

from ..database import get_db
from ..glb_optimizer import GLBError, optimize_glb
from ..models import PremiumSubscription, Product, Product3DAsset, User
from ..security import get_current_admin_user, get_current_user
from ..services.ai_telemetry_service import record_glb_optimization_metric

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/premium-3d",
    tags=["Premium 3D"],
)

BUCKET = "penguin-store-3d"
PUBLIC_IMAGE_BUCKET = "penguin-store-assets"

# Signed URLs live 15 minutes and are cached server-side for 10 minutes so
# opening a 3D model does not need a Supabase round-trip every time.
SIGNED_URL_LIFETIME = 900
SIGNED_URL_CACHE_SECONDS = 600
_signed_url_cache: dict[int, tuple[str, float]] = {}
_signed_url_lock = Lock()

# Raw uploads may be large downloads from the internet; they are optimised
# (textures capped at 512 px) before being stored. Supabase free tier caps a
# single object at 50 MB, so the optimised file must fit that limit.
MAX_GLB_BYTES = 60 * 1024 * 1024
MAX_STORED_GLB_BYTES = 50 * 1024 * 1024
MAX_POSTER_BYTES = 10 * 1024 * 1024

DEMO_DURATION = timedelta(hours=1)
_demo_expires: dict[int, datetime] = {}
_demo_lock = Lock()


class ModelRegistration(BaseModel):
    display_name: str = Field(
        default="3D Product View",
        min_length=1,
        max_length=150,
    )
    variant_name: str | None = Field(
        default=None,
        max_length=100,
    )
    storage_path: str = Field(
        min_length=1,
        max_length=512,
    )
    file_size_bytes: int | None = Field(
        default=None,
        gt=0,
    )


class ModelActivation(BaseModel):
    is_active: bool


def _demo_enabled(request: Request) -> bool:
    if os.getenv(
        "ENVIRONMENT",
        "development",
    ).lower() != "development":
        return False

    if os.getenv(
        "ENABLE_PREMIUM_DEMO",
        "false",
    ).lower() != "true":
        return False

    if (
        request.client is None
        or request.client.host not in (
            "127.0.0.1",
            "::1",
        )
    ):
        return False

    host = urlsplit(
        "http://" + request.headers.get("host", "")
    ).hostname

    return host in (
        "127.0.0.1",
        "localhost",
        "::1",
    )


def _demo_expiry(
    request: Request,
    user_id: int,
) -> datetime | None:
    if not _demo_enabled(request):
        return None

    with _demo_lock:
        expiry = _demo_expires.get(user_id)

        if (
            expiry is not None
            and expiry <= datetime.now(timezone.utc)
        ):
            _demo_expires.pop(user_id, None)
            return None

        return expiry


def _is_premium(
    subscription: PremiumSubscription | None,
) -> bool:
    if subscription is None:
        return False

    if subscription.status not in (
        "active",
        "trialing",
    ):
        return False

    expiry = subscription.current_period_end

    if expiry is None:
        return False

    if expiry.tzinfo is None:
        expiry = expiry.replace(
            tzinfo=timezone.utc
        )

    return expiry > datetime.now(timezone.utc)


def _subscription_for(
    db: Session,
    user_id: int,
) -> PremiumSubscription | None:
    return db.query(PremiumSubscription).filter(
        PremiumSubscription.user_id == user_id
    ).first()


def _active_assets(
    db: Session,
    product_id: int,
) -> list[Product3DAsset]:
    return db.query(Product3DAsset).filter(
        Product3DAsset.product_id == product_id,
        Product3DAsset.is_active.is_(True),
    ).order_by(
        Product3DAsset.id
    ).all()


def _service_client():
    from app.core.supabase_rest import get_supabase_client

    url = os.getenv(
        "SUPABASE_URL",
        "",
    ).strip().rstrip("/")

    key = os.getenv(
        "SUPABASE_SERVICE_KEY",
        "",
    ).strip()

    if not url or not key:
        raise HTTPException(
            status_code=503,
            detail=(
                "Private 3D storage is "
                "not configured yet."
            ),
        )

    return url, get_supabase_client()


def _sign_asset(
    asset: Product3DAsset,
) -> str:
    if (
        asset.storage_bucket != BUCKET
        or asset.model_format != "glb"
    ):
        raise HTTPException(
            status_code=503,
            detail="3D model metadata is invalid.",
        )

    with _signed_url_lock:
        cached = _signed_url_cache.get(asset.id)

    if cached is not None and cached[1] > time.monotonic():
        return cached[0]

    url, client = _service_client()

    try:
        signed = None
        last_sign_err: Exception | None = None
        for attempt in range(3):
            try:
                signed = client.storage.from_(
                    BUCKET
                ).create_signed_url(
                    asset.storage_path,
                    SIGNED_URL_LIFETIME,
                )
                break
            except Exception as sign_exc:
                last_sign_err = sign_exc
                time.sleep(0.2 * (attempt + 1))
        if signed is None and last_sign_err is not None:
            raise last_sign_err

        signed_url = (
            signed.get("signedURL")
            or signed.get("signedUrl")
        )

        if (
            not isinstance(signed_url, str)
            or not signed_url
        ):
            raise ValueError(
                "Supabase returned no signed URL."
            )

        if signed_url.startswith("/object/"):
            signed_url = (
                f"{url}/storage/v1{signed_url}"
            )

        elif signed_url.startswith("/storage/v1/"):
            signed_url = f"{url}{signed_url}"

        parsed_signed_url = urlsplit(signed_url)
        parsed_supabase_url = urlsplit(url)

        if (
            parsed_signed_url.scheme != "https"
            or parsed_signed_url.netloc
            != parsed_supabase_url.netloc
        ):
            raise ValueError(
                "Unexpected signed URL origin."
            )

        with _signed_url_lock:
            _signed_url_cache[asset.id] = (
                signed_url,
                time.monotonic() + SIGNED_URL_CACHE_SECONDS,
            )

        return signed_url

    except Exception:
        logger.exception(
            "Failed to sign private GLB asset id=%s",
            asset.id,
        )

        raise HTTPException(
            status_code=503,
            detail=(
                "3D model is temporarily unavailable."
            ),
        )


# Public list of products with active 3D models.
# Automatically includes newly uploaded 3D shirts.
def _optimize_for_web(content: bytes) -> bytes:
    """Validate + cap embedded textures at 512 px. Falls back to original."""
    t0 = time.perf_counter()
    try:
        optimized, stats = optimize_glb(content)
    except GLBError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    orig_kb = round(len(content) / 1024.0, 2)
    opt_kb = round(len(optimized) / 1024.0, 2)
    reduction_pct = (
        round(((orig_kb - opt_kb) / orig_kb) * 100.0, 2)
        if orig_kb > 0 and orig_kb >= opt_kb
        else 0.0
    )
    try:
        record_glb_optimization_metric(
            original_size_kb=orig_kb,
            optimized_size_kb=opt_kb,
            reduction_percent=reduction_pct,
            latency_ms=elapsed_ms,
        )
    except Exception:
        pass

    logger.info("GLB optimisation: %s", stats)

    if len(optimized) > MAX_STORED_GLB_BYTES:
        raise HTTPException(
            status_code=413,
            detail=(
                "Model is still larger than 50 MB after optimisation. "
                "Compress it (e.g. gltf.report / gltfpack) and retry."
            ),
        )

    return optimized


@router.get("/catalog")
def get_3d_catalog(
    db: Session = Depends(get_db),
):
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_3d_catalog_ids_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        ids = fetch_3d_catalog_ids_https(bucket=BUCKET)
        return {"product_ids": ids, "count": len(ids)}

    try:
        rows = db.query(
            Product3DAsset.product_id
        ).filter(
            Product3DAsset.is_active.is_(True),
            Product3DAsset.storage_bucket == BUCKET,
            Product3DAsset.model_format == "glb",
        ).distinct().all()
        ids = sorted(row[0] for row in rows)
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        ids = fetch_3d_catalog_ids_https(bucket=BUCKET)

    return {
        "product_ids": ids,
        "count": len(ids),
    }


@router.get("/products/{product_id}")
def get_product_3d_availability(
    product_id: int,
    db: Session = Depends(get_db),
):
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_product_3d_assets_https,
        fetch_product_by_id_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        product_row = fetch_product_by_id_https(product_id)
        if product_row is None:
            raise HTTPException(status_code=404, detail="Product not found.")
        raw_assets = fetch_product_3d_assets_https(product_id, bucket=BUCKET)
        return {
            "product_id": product_id,
            "has_3d": bool(raw_assets),
            "models": [
                {
                    "id": int(a["id"]),
                    "display_name": a.get("display_name") or "3D View",
                    "variant_name": a.get("variant_name") or "Default",
                }
                for a in raw_assets
            ],
        }

    try:
        exists = db.query(Product.id).filter(
            Product.id == product_id
        ).first()

        if exists is None:
            raise HTTPException(
                status_code=404,
                detail="Product not found.",
            )

        assets = _active_assets(db, product_id)

        return {
            "product_id": product_id,
            "has_3d": bool(assets),
            "models": [
                {
                    "id": asset.id,
                    "display_name": asset.display_name,
                    "variant_name": asset.variant_name,
                }
                for asset in assets
            ],
        }
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        product_row = fetch_product_by_id_https(product_id)
        if product_row is None:
            raise HTTPException(status_code=404, detail="Product not found.")
        raw_assets = fetch_product_3d_assets_https(product_id, bucket=BUCKET)
        return {
            "product_id": product_id,
            "has_3d": bool(raw_assets),
            "models": [
                {
                    "id": int(a["id"]),
                    "display_name": a.get("display_name") or "3D View",
                    "variant_name": a.get("variant_name") or "Default",
                }
                for a in raw_assets
            ],
        }


@router.get("/me")
def get_my_premium_status(
    request: Request,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    subscription = _subscription_for(
        db,
        current_user.id,
    )

    paid_access = _is_premium(subscription)

    demo_expiry = _demo_expiry(
        request,
        current_user.id,
    )

    demo_access = (
        not paid_access
        and demo_expiry is not None
    )

    current_period_end = (
        subscription.current_period_end
        if paid_access and subscription
        else (
            demo_expiry
            if demo_access
            else (
                subscription.current_period_end
                if subscription
                else None
            )
        )
    )

    return {
        "is_premium": paid_access or demo_access,
        "is_demo": demo_access,
        "demo_available": _demo_enabled(request),
        "plan_name": (
            "demo"
            if demo_access
            else (
                subscription.plan_name
                if subscription
                else None
            )
        ),
        "status": (
            "demo"
            if demo_access
            else (
                subscription.status
                if subscription
                else "inactive"
            )
        ),
        "current_period_end": (
            current_period_end.isoformat()
            if current_period_end
            else None
        ),
    }


# Activate one hour of free local demo access.
@router.post("/demo/activate")
def activate_demo(
    request: Request,
    current_user: User = Depends(get_current_user),
):
    if not _demo_enabled(request):
        raise HTTPException(
            status_code=404,
            detail=(
                "Demo is only available "
                "on local development."
            ),
        )

    with _demo_lock:
        existing = _demo_expires.get(
            current_user.id
        )

        if (
            existing is not None
            and existing > datetime.now(timezone.utc)
        ):
            expiry = existing

        else:
            expiry = (
                datetime.now(timezone.utc)
                + DEMO_DURATION
            )

            _demo_expires[
                current_user.id
            ] = expiry

    return {
        "is_premium": True,
        "is_demo": True,
        "status": "demo",
        "expires_at": expiry.isoformat(),
    }


# End local demo access without touching Stripe.
@router.post("/demo/deactivate")
def deactivate_demo(
    request: Request,
    current_user: User = Depends(get_current_user),
):
    if not _demo_enabled(request):
        raise HTTPException(
            status_code=404,
            detail=(
                "Demo is only available "
                "on local development."
            ),
        )

    with _demo_lock:
        _demo_expires.pop(
            current_user.id,
            None,
        )

    return {
        "is_demo": False,
        "status": "inactive",
    }


@router.get(
    "/products/{product_id}/models/{model_id}/view"
)
def get_signed_model_url(
    product_id: int,
    model_id: int,
    request: Request,
    response: Response,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    response.headers["Cache-Control"] = "no-store"

    asset = db.query(Product3DAsset).filter(
        Product3DAsset.id == model_id,
        Product3DAsset.product_id == product_id,
        Product3DAsset.is_active.is_(True),
    ).first()

    if asset is None:
        raise HTTPException(
            status_code=404,
            detail="3D model not available.",
        )

    subscription = _subscription_for(
        db,
        current_user.id,
    )

    has_paid_premium = _is_premium(
        subscription
    )

    has_demo_access = (
        _demo_expiry(
            request,
            current_user.id,
        ) is not None
    )

    if (
        not has_paid_premium
        and not has_demo_access
    ):
        raise HTTPException(
            status_code=403,
            detail=(
                "An active Premium subscription "
                "is required."
            ),
        )

    return {
        "product_id": product_id,
        "model_id": model_id,
        "model_url": _sign_asset(asset),
        "expires_in_seconds": SIGNED_URL_LIFETIME,
        "format": "glb",
    }


# Keep original admin model registration endpoint.
@router.post(
    "/admin/products/{product_id}/models",
    status_code=status.HTTP_201_CREATED,
)
def register_model(
    product_id: int,
    payload: ModelRegistration,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    exists = db.query(Product.id).filter(
        Product.id == product_id
    ).first()

    if exists is None:
        raise HTTPException(
            status_code=404,
            detail="Product not found.",
        )

    path = payload.storage_path

    if (
        not path.startswith(f"products/{product_id}/")
        or ".." in path
        or "//" in path
        or not re.fullmatch(
            r"[A-Za-z0-9_./-]+\.glb",
            path,
        )
    ):
        raise HTTPException(
            status_code=422,
            detail=(
                "Use a valid GLB path such as "
                f"products/{product_id}/model.glb"
            ),
        )

    asset = Product3DAsset(
        product_id=product_id,
        display_name=payload.display_name,
        variant_name=payload.variant_name,
        storage_bucket=BUCKET,
        storage_path=path,
        model_format="glb",
        file_size_bytes=payload.file_size_bytes,
        is_active=False,
    )

    try:
        db.add(asset)
        db.commit()
        db.refresh(asset)

    except IntegrityError:
        db.rollback()

        raise HTTPException(
            status_code=409,
            detail=(
                "This GLB path is already registered."
            ),
        )

    return {
        "id": asset.id,
        "product_id": product_id,
        "storage_path": path,
        "is_active": False,
    }


@router.patch("/admin/models/{model_id}")
def update_model_activation(
    model_id: int,
    payload: ModelActivation,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    from app.core.supabase_rest import (
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    client = get_supabase_client()
    res = (
        client.table("product_3d_assets")
        .update({"is_active": bool(payload.is_active)})
        .eq("id", model_id)
        .execute()
    )
    rows = res.data or []
    if not rows:
        raise HTTPException(
            status_code=404,
            detail="3D model not found.",
        )

    invalidate_supabase_rest_cache()
    with _signed_url_lock:
        _signed_url_cache.pop(model_id, None)

    return {
        "id": model_id,
        "is_active": bool(rows[0].get("is_active", payload.is_active)),
    }


def _upload_poster_image(poster: UploadFile | None) -> str | None:
    """Upload a manual cover photo or auto-captured <model-viewer> PNG poster to Supabase Storage.

    Transparent RGBA renders from <model-viewer>.toBlob() are composited onto a crisp
    Arctic Studio backdrop so thumbnails never turn black and match the 3D viewer lighting.
    """
    if poster is None or not poster.filename:
        return None
    try:
        from PIL import Image

        raw = poster.file.read(MAX_POSTER_BYTES + 1)
        if not raw or len(raw) > MAX_POSTER_BYTES:
            raise ValueError("Poster exceeds maximum size limit.")

        with Image.open(io.BytesIO(raw)) as im:
            im.thumbnail((1024, 1024))
            if im.mode in ("RGBA", "LA") or (
                im.mode == "P" and "transparency" in im.info
            ):
                rgba = im.convert("RGBA")
                w, h = rgba.size
                bg = Image.new("RGBA", (w, h))
                px = bg.load()
                top, bottom = (238, 246, 255), (210, 231, 250)
                for y in range(h):
                    t = y / max(1, h - 1)
                    row = (
                        round(top[0] + (bottom[0] - top[0]) * t),
                        round(top[1] + (bottom[1] - top[1]) * t),
                        round(top[2] + (bottom[2] - top[2]) * t),
                        255,
                    )
                    for x in range(w):
                        px[x, y] = row
                composed = Image.alpha_composite(bg, rgba).convert("RGB")
            else:
                composed = im.convert("RGB")

            buf = io.BytesIO()
            composed.save(buf, format="JPEG", quality=90, optimize=True)

        _, client = _service_client()
        poster_path = f"showcase/{uuid.uuid4().hex}.jpg"
        bucket = client.storage.from_(PUBLIC_IMAGE_BUCKET)
        bucket.upload(
            path=poster_path,
            file=buf.getvalue(),
            file_options={
                "content-type": "image/jpeg",
                "upsert": "false",
                "cache-control": "31536000",
            },
        )
        return bucket.get_public_url(poster_path)
    except HTTPException:
        raise
    except Exception:
        logger.exception("Poster upload failed; using generated poster fallback.")
        return None
    finally:
        try:
            poster.file.close()
        except Exception:
            pass


# Existing admin GLB upload (now also accepts an optional auto-captured 3D poster).
@router.post(
    "/admin/products/{product_id}/upload",
    status_code=status.HTTP_201_CREATED,
)
def upload_product_glb(
    product_id: int,
    file: UploadFile = File(...),
    display_name: str = Form("3D Product View"),
    variant_name: str = Form(""),
    poster: UploadFile | None = File(None),
    update_product_image: bool = Form(False),
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    from app.core.supabase_rest import (
        fetch_product_by_id_https,
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    exists = fetch_product_by_id_https(product_id)

    if exists is None:
        raise HTTPException(
            status_code=404,
            detail="Product not found.",
        )

    display_name = display_name.strip()
    variant_name = variant_name.strip()

    if (
        not 1 <= len(display_name) <= 150
        or len(variant_name) > 100
    ):
        raise HTTPException(
            status_code=422,
            detail="Invalid model name or variant.",
        )

    content = _read_glb_upload(file)
    asset = _store_glb(
        db,
        product_id,
        content,
        display_name=display_name,
        variant_name=variant_name or None,
    )

    poster_url = _upload_poster_image(poster)
    existing_img = str(exists.get("image_url") or "").strip()
    if poster_url and (
        update_product_image
        or not existing_img
        or existing_img.startswith("/api/premium-3d/poster/")
    ):
        try:
            get_supabase_client().table("products").update(
                {"image_url": poster_url}
            ).eq("id", product_id).execute()
            invalidate_supabase_rest_cache()
        except Exception:
            logger.exception("Could not update product %s poster URL", product_id)

    return {
        "id": asset.id,
        "product_id": product_id,
        "storage_path": asset.storage_path,
        "is_active": True,
        "file_size_bytes": len(content),
        "poster_url": poster_url,
    }


# Existing secure admin preview.
@router.get("/admin/models/{model_id}/preview")
def preview_admin_model(
    model_id: int,
    response: Response,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    from app.core.supabase_rest import get_supabase_client

    response.headers["Cache-Control"] = "no-store"

    client = get_supabase_client()
    res = (
        client.table("product_3d_assets")
        .select("*")
        .eq("id", model_id)
        .eq("is_active", True)
        .limit(1)
        .execute()
    )
    rows = res.data or []
    if not rows:
        raise HTTPException(
            status_code=404,
            detail="Active 3D model not found.",
        )

    r = rows[0]
    asset = Product3DAsset(
        id=int(r["id"]),
        product_id=int(r["product_id"]),
        storage_bucket=str(r.get("storage_bucket") or BUCKET),
        storage_path=str(r.get("storage_path") or ""),
        model_format=str(r.get("model_format") or "glb"),
        is_active=True,
    )

    return {
        "product_id": asset.product_id,
        "model_id": model_id,
        "model_url": _sign_asset(asset),
        "expires_in_seconds": SIGNED_URL_LIFETIME,
        "format": "glb",
    }

@router.get(
    "/products/{product_id}/models/{model_id}/showcase"
)
def view_public_3d_showcase(
    product_id: int,
    model_id: int,
    response: Response,
    db: Session = Depends(get_db),
):
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_3d_asset_by_id_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    response.headers["Cache-Control"] = "no-store"

    showcase_enabled = (
        os.getenv(
            "ENABLE_PUBLIC_3D_SHOWCASE",
            "true",
        ).strip().lower() not in ("false", "0", "no")
    )

    if not showcase_enabled:
        raise HTTPException(
            status_code=404,
            detail="Public 3D showcase is unavailable.",
        )

    asset = None
    if is_pg_tcp_reachable():
        try:
            asset = db.query(Product3DAsset).filter(
                Product3DAsset.id == model_id,
                Product3DAsset.product_id == product_id,
                Product3DAsset.is_active.is_(True),
                Product3DAsset.storage_bucket == BUCKET,
                Product3DAsset.model_format == "glb",
            ).first()
        except OperationalError:
            db.rollback()
            mark_pg_tcp_unreachable()

    if asset is None and not is_pg_tcp_reachable():
        asset = fetch_3d_asset_by_id_https(product_id, model_id, bucket=BUCKET)

    if asset is None:
        raise HTTPException(
            status_code=404,
            detail="3D model not found.",
        )

    return {
        "product_id": product_id,
        "model_id": model_id,
        "model_url": _sign_asset(asset),
        "expires_in_seconds": SIGNED_URL_LIFETIME,
        "format": "glb",
        "access_type": "public_demo",
        "message": (
            "Free preview of Penguin Premium 3D. "
            "Subscriptions are coming soon."
        ),
    }



# ---------------------------------------------------------------------------
# 3D Studio additions: standalone uploads, 3D filter feed, management.
# Everything below is additive; the endpoints above are unchanged.
# ---------------------------------------------------------------------------

SHOWCASE_CATEGORY = "3D Models"

_PUBLIC_PRODUCT_FIELDS = (
    "id",
    "name",
    "description",
    "price",
    "original_price",
    "image_url",
    "category",
    "rating",
    "reviews",
    "discount_percent",
    "is_featured",
)


def _public_product(product: Product) -> dict:
    return {
        field: getattr(product, field, None)
        for field in _PUBLIC_PRODUCT_FIELDS
    }


def _store_glb(
    db: Session,
    product_id: int,
    content: bytes,
    display_name: str,
    variant_name: str | None,
) -> Product3DAsset:
    """Upload an (already optimised) GLB to private storage + register it over HTTPS."""
    from app.core.supabase_rest import invalidate_supabase_rest_cache

    _, client = _service_client()

    storage_path = f"products/{product_id}/{uuid.uuid4().hex}.glb"
    storage = client.storage.from_(BUCKET)

    try:
        storage.upload(
            path=storage_path,
            file=content,
            file_options={
                "content-type": "model/gltf-binary",
                "upsert": "false",
                "cache-control": "3600",
            },
        )
    except Exception:
        logger.exception("Private GLB upload failed for product %s", product_id)
        raise HTTPException(
            status_code=502,
            detail="GLB upload to Supabase failed.",
        )

    try:
        res = (
            client.table("product_3d_assets")
            .insert(
                {
                    "product_id": product_id,
                    "display_name": display_name,
                    "variant_name": variant_name or None,
                    "storage_bucket": BUCKET,
                    "storage_path": storage_path,
                    "model_format": "glb",
                    "file_size_bytes": len(content),
                    "is_active": True,
                }
            )
            .execute()
        )
        rows = res.data or []
        if not rows:
            raise RuntimeError("No row returned from product_3d_assets insert.")
        r = rows[0]
        invalidate_supabase_rest_cache()
        return Product3DAsset(
            id=int(r["id"]),
            product_id=int(r["product_id"]),
            display_name=str(r.get("display_name") or display_name),
            variant_name=r.get("variant_name"),
            storage_bucket=str(r.get("storage_bucket") or BUCKET),
            storage_path=str(r.get("storage_path") or storage_path),
            model_format="glb",
            file_size_bytes=len(content),
            is_active=True,
        )
    except Exception:
        logger.exception("DB registration failed for %s", storage_path)
        try:
            storage.remove([storage_path])
        except Exception:
            logger.exception("Failed to clean orphan GLB %s", storage_path)
        raise HTTPException(status_code=500, detail="GLB registration failed.")


def _read_glb_upload(file: UploadFile) -> bytes:
    if not file.filename or not file.filename.lower().endswith(".glb"):
        raise HTTPException(status_code=415, detail="Upload a .glb model file.")

    try:
        content = file.file.read(MAX_GLB_BYTES + 1)
    finally:
        file.file.close()

    if not content or len(content) > MAX_GLB_BYTES:
        raise HTTPException(
            status_code=413,
            detail="GLB must be nonempty and at most 60 MB.",
        )

    if content[:4] != b"glTF":
        raise HTTPException(status_code=422, detail="Invalid GLB 2.0 file.")

    return _optimize_for_web(content)


def _poster_png(name: str, size: int = 640) -> bytes:
    """Icy-blue placeholder poster for 3D-only products."""
    from PIL import Image, ImageDraw, ImageFont

    img = Image.new("RGB", (size, size))
    px = img.load()

    top, bottom = (232, 244, 255), (160, 205, 245)
    for y in range(size):
        t = y / (size - 1)
        row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = row

    draw = ImageDraw.Draw(img)

    # Simple cube glyph = "3D model".
    c, s = size // 2, size // 5
    ink = (30, 136, 229)
    draw.polygon([(c, c - s - 40), (c + s, c - s // 2 - 40), (c, c - 40),
                  (c - s, c - s // 2 - 40)], outline=ink, width=6)
    draw.polygon([(c - s, c - s // 2 - 40), (c, c - 40), (c, c + s - 40),
                  (c - s, c + s // 2 - 40)], outline=ink, width=6)
    draw.polygon([(c + s, c - s // 2 - 40), (c, c - 40), (c, c + s - 40),
                  (c + s, c + s // 2 - 40)], outline=ink, width=6)

    try:
        title_font = ImageFont.load_default(size=34)
        badge_font = ImageFont.load_default(size=28)
    except TypeError:
        title_font = badge_font = ImageFont.load_default()

    words, lines, line = name.split(), [], ""
    for word in words:
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=title_font) > size - 80 and line:
            lines.append(line)
            line = word
        else:
            line = trial
    if line:
        lines.append(line)

    y = c + s + 10
    for text in lines[:2]:
        w = draw.textlength(text, font=title_font)
        draw.text(((size - w) / 2, y), text, fill=(24, 54, 96), font=title_font)
        y += 44

    badge = "3D VIEW"
    bw = draw.textlength(badge, font=badge_font)
    draw.rounded_rectangle([(size - bw - 56, 24), (size - 24, 72)],
                           radius=22, fill=ink)
    draw.text((size - bw - 40, 33), badge, fill="white", font=badge_font)

    out = io.BytesIO()
    img.save(out, format="PNG", optimize=True)
    return out.getvalue()


@router.get("/poster/{product_id}.png")
def get_generated_poster(
    product_id: int,
    db: Session = Depends(get_db),
):
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_product_by_id_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    product_name = None
    if is_pg_tcp_reachable():
        try:
            row = db.query(Product.name).filter(Product.id == product_id).first()
            if row is not None:
                product_name = row.name
        except OperationalError:
            db.rollback()
            mark_pg_tcp_unreachable()

    if product_name is None and not is_pg_tcp_reachable():
        row_dict = fetch_product_by_id_https(product_id)
        if row_dict is not None:
            product_name = row_dict.get("name") or "3D Model"

    if product_name is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    return Response(
        content=_poster_png(product_name or "3D Model"),
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/showcase")
def get_3d_showcase(
    response: Response,
    db: Session = Depends(get_db),
):
    """Public feed for the '3D' filter: products + their active models."""
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_3d_showcase_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    response.headers["Cache-Control"] = "public, max-age=30"

    if not is_pg_tcp_reachable():
        return fetch_3d_showcase_https(bucket=BUCKET)

    try:
        assets = db.query(Product3DAsset).filter(
            Product3DAsset.is_active.is_(True),
            Product3DAsset.storage_bucket == BUCKET,
            Product3DAsset.model_format == "glb",
        ).order_by(Product3DAsset.id).all()
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        return fetch_3d_showcase_https(bucket=BUCKET)

    by_product: dict[int, list[Product3DAsset]] = {}
    for asset in assets:
        by_product.setdefault(asset.product_id, []).append(asset)

    if not by_product:
        return {"count": 0, "items": []}

    from sqlalchemy.orm import load_only
    products = (
        db.query(Product)
        .options(
            load_only(
                Product.id,
                Product.name,
                Product.description,
                Product.price,
                Product.original_price,
                Product.image_url,
                Product.category,
                Product.rating,
                Product.reviews,
                Product.discount_percent,
                Product.is_featured,
            )
        )
        .filter(Product.id.in_(list(by_product)))
        .all()
    )

    items = []
    for product in sorted(products, key=lambda p: p.id, reverse=True):
        item = _public_product(product)
        item["models"] = [
            {
                "id": a.id,
                "display_name": a.display_name,
                "variant_name": a.variant_name,
                "file_size_bytes": a.file_size_bytes,
            }
            for a in by_product[product.id]
        ]
        items.append(item)

    return {"count": len(items), "items": items}


@router.get("/admin/models")
def list_admin_models(
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    from sqlalchemy.exc import OperationalError
    from app.core.supabase_rest import (
        fetch_3d_showcase_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        showcase = fetch_3d_showcase_https(bucket=BUCKET)
        items = []
        for p in showcase.get("items", []):
            for m in p.get("models", []):
                items.append(
                    {
                        "id": m["id"],
                        "product_id": p["id"],
                        "product_name": p.get("name"),
                        "display_name": m.get("display_name") or "3D View",
                        "variant_name": m.get("variant_name") or "Default",
                        "file_size_bytes": m.get("file_size_bytes"),
                        "is_active": True,
                        "created_at": None,
                    }
                )
        return {"items": items}

    try:
        rows = db.query(Product3DAsset, Product.name).join(
            Product, Product.id == Product3DAsset.product_id
        ).order_by(Product3DAsset.id.desc()).all()
    except OperationalError:
        db.rollback()
        mark_pg_tcp_unreachable()
        showcase = fetch_3d_showcase_https(bucket=BUCKET)
        items = []
        for p in showcase.get("items", []):
            for m in p.get("models", []):
                items.append(
                    {
                        "id": m["id"],
                        "product_id": p["id"],
                        "product_name": p.get("name"),
                        "display_name": m.get("display_name") or "3D View",
                        "variant_name": m.get("variant_name") or "Default",
                        "file_size_bytes": m.get("file_size_bytes"),
                        "is_active": True,
                        "created_at": None,
                    }
                )
        return {"items": items}

    return {
        "items": [
            {
                "id": a.id,
                "product_id": a.product_id,
                "product_name": name,
                "display_name": a.display_name,
                "variant_name": a.variant_name,
                "file_size_bytes": a.file_size_bytes,
                "is_active": bool(a.is_active),
                "created_at": a.created_at.isoformat() if a.created_at else None,
            }
            for a, name in rows
        ]
    }


@router.delete("/admin/models/{model_id}")
def delete_admin_model(
    model_id: int,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    from app.core.supabase_rest import (
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    client = get_supabase_client()
    res = (
        client.table("product_3d_assets")
        .select("*")
        .eq("id", model_id)
        .limit(1)
        .execute()
    )
    rows = res.data or []
    if not rows:
        raise HTTPException(status_code=404, detail="3D model not found.")

    asset = rows[0]
    if int(asset.get("product_id", -1)) == 144 and asset.get("is_active"):
        raise HTTPException(
            status_code=403,
            detail="Reference 3D showcase asset for Product #144 is protected.",
        )

    path = str(asset.get("storage_path") or "")
    bucket = str(asset.get("storage_bucket") or BUCKET)

    client.table("product_3d_assets").delete().eq("id", model_id).execute()
    invalidate_supabase_rest_cache()

    with _signed_url_lock:
        _signed_url_cache.pop(model_id, None)

    try:
        if path:
            client.storage.from_(bucket).remove([path])
    except Exception:
        logger.exception("Could not remove storage object %s", path)

    return {"id": model_id, "deleted": True}


@router.post(
    "/admin/showcase-upload",
    status_code=status.HTTP_201_CREATED,
)
def upload_standalone_3d_product(
    file: UploadFile = File(...),
    name: str = Form(...),
    price: float = Form(...),
    category: str = Form(SHOWCASE_CATEGORY),
    description: str = Form(""),
    variant_name: str = Form(""),
    is_featured: bool = Form(False),
    poster: UploadFile | None = File(None),
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    """
    One-step 3D upload: creates a store product (so it can be searched,
    filtered and bought) and attaches the optimised GLB to it over HTTPS.
    Separate 2D image upload is optional: accepts either a manual image,
    an auto-captured <model-viewer> snapshot, or falls back to generated poster.
    """
    from app.core.supabase_rest import (
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    name = name.strip()
    category = category.strip() or SHOWCASE_CATEGORY

    if not 1 <= len(name) <= 150:
        raise HTTPException(status_code=422, detail="Name must be 1-150 characters.")
    if not 0 < price <= 1_000_000:
        raise HTTPException(status_code=422, detail="Enter a valid price.")
    if len(variant_name.strip()) > 100:
        raise HTTPException(status_code=422, detail="Variant name too long.")

    content = _read_glb_upload(file)
    poster_url = _upload_poster_image(poster)

    client = get_supabase_client()
    try:
        res = (
            client.table("products")
            .insert(
                {
                    "name": name,
                    "description": description.strip() or f"Interactive 3D model: {name}",
                    "price": float(price),
                    "image_url": poster_url or "",
                    "category": category,
                    "rating": 0.0,
                    "reviews": 0,
                    "is_featured": bool(is_featured),
                    "stock": 50,
                    "fulfillment_type": "IN_HOUSE",
                    "supplier_id": "PENGUIN_DIRECT",
                }
            )
            .execute()
        )
        rows = res.data or []
        if not rows:
            raise RuntimeError("No product row returned from Supabase insert.")
        product_row = rows[0]
        product_id = int(product_row["id"])

        if not poster_url:
            generated_url = f"/api/premium-3d/poster/{product_id}.png"
            client.table("products").update({"image_url": generated_url}).eq(
                "id", product_id
            ).execute()
            product_row["image_url"] = generated_url

        invalidate_supabase_rest_cache()
    except Exception:
        logger.exception("Failed creating 3D product")
        raise HTTPException(status_code=500, detail="Could not create product.")

    try:
        asset = _store_glb(
            db,
            product_id,
            content,
            display_name=f"{name} 3D View"[:150],
            variant_name=variant_name.strip() or None,
        )
    except HTTPException:
        try:
            client.table("products").delete().eq("id", product_id).execute()
            invalidate_supabase_rest_cache()
        except Exception:
            pass
        raise

    return {
        "product_id": product_id,
        "model_id": asset.id,
        "name": product_row.get("name") or name,
        "category": product_row.get("category") or category,
        "image_url": product_row.get("image_url") or "",
        "file_size_bytes": asset.file_size_bytes,
        "is_active": True,
    }
