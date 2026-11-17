
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

    return url, create_client(url, key)


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
        signed = client.storage.from_(
            BUCKET
        ).create_signed_url(
            asset.storage_path,
            SIGNED_URL_LIFETIME,
        )

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
    try:
        optimized, stats = optimize_glb(content)
    except GLBError as exc:
        raise HTTPException(status_code=422, detail=str(exc))

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
    rows = db.query(
        Product3DAsset.product_id
    ).filter(
        Product3DAsset.is_active.is_(True),
        Product3DAsset.storage_bucket == BUCKET,
        Product3DAsset.model_format == "glb",
    ).distinct().all()

    ids = sorted(row[0] for row in rows)

    return {
        "product_ids": ids,
        "count": len(ids),
    }


@router.get("/products/{product_id}")
def get_product_3d_availability(
    product_id: int,
    db: Session = Depends(get_db),
):
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
    asset = db.get(
        Product3DAsset,
        model_id,
    )

    if asset is None:
        raise HTTPException(
            status_code=404,
            detail="3D model not found.",
        )

    asset.is_active = payload.is_active

    db.commit()
    db.refresh(asset)

    with _signed_url_lock:
        _signed_url_cache.pop(asset.id, None)

    return {
        "id": asset.id,
        "is_active": asset.is_active,
    }


# Existing admin GLB upload.
@router.post(
    "/admin/products/{product_id}/upload",
    status_code=status.HTTP_201_CREATED,
)
def upload_product_glb(
    product_id: int,
    file: UploadFile = File(...),
    display_name: str = Form("3D Product View"),
    variant_name: str = Form(""),
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

    if (
        not file.filename
        or not file.filename.lower().endswith(".glb")
    ):
        raise HTTPException(
            status_code=415,
            detail="Upload a .glb model file.",
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

    try:
        content = file.file.read(
            MAX_GLB_BYTES + 1
        )

    finally:
        file.file.close()

    if (
        not content
        or len(content) > MAX_GLB_BYTES
    ):
        raise HTTPException(
            status_code=413,
            detail=(
                "GLB must be nonempty "
                "and at most 60 MB."
            ),
        )

    if (
        len(content) < 20
        or content[:4] != b"glTF"
        or int.from_bytes(
            content[4:8],
            "little",
        ) != 2
        or int.from_bytes(
            content[8:12],
            "little",
        ) != len(content)
        or content[16:20] != b"JSON"
    ):
        raise HTTPException(
            status_code=422,
            detail="Invalid GLB 2.0 file.",
        )

    content = _optimize_for_web(content)

    _, client = _service_client()

    storage_path = (
        f"products/{product_id}/"
        f"{uuid.uuid4().hex}.glb"
    )

    storage = client.storage.from_(BUCKET)

    try:
        storage.upload(
            path=storage_path,
            file=content,
            file_options={
                "content-type": "model/gltf-binary",
                "upsert": "false",
            },
        )

    except Exception:
        logger.exception(
            "Private GLB upload failed "
            "for product %s",
            product_id,
        )

        raise HTTPException(
            status_code=502,
            detail=(
                "GLB upload to Supabase failed."
            ),
        )

    asset = Product3DAsset(
        product_id=product_id,
        display_name=display_name,
        variant_name=variant_name or None,
        storage_bucket=BUCKET,
        storage_path=storage_path,
        model_format="glb",
        file_size_bytes=len(content),
        is_active=True,
    )

    try:
        db.add(asset)
        db.commit()
        db.refresh(asset)

    except Exception:
        db.rollback()

        logger.exception(
            "Database registration failed "
            "for model %s",
            storage_path,
        )

        try:
            storage.remove([storage_path])

        except Exception:
            logger.exception(
                "Failed to clean up orphan GLB "
                "at %s",
                storage_path,
            )

        raise HTTPException(
            status_code=500,
            detail="GLB registration failed.",
        )

    return {
        "id": asset.id,
        "product_id": product_id,
        "storage_path": storage_path,
        "is_active": True,
        "file_size_bytes": len(content),
    }


# Existing secure admin preview.
@router.get("/admin/models/{model_id}/preview")
def preview_admin_model(
    model_id: int,
    response: Response,
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    response.headers["Cache-Control"] = "no-store"

    asset = db.query(Product3DAsset).filter(
        Product3DAsset.id == model_id,
        Product3DAsset.is_active.is_(True),
    ).first()

    if asset is None:
        raise HTTPException(
            status_code=404,
            detail="Active 3D model not found.",
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
    response.headers["Cache-Control"] = "no-store"

    showcase_enabled = (
        os.getenv(
            "ENABLE_PUBLIC_3D_SHOWCASE",
            "false",
        ).lower() == "true"
    )

    if not showcase_enabled:
        raise HTTPException(
            status_code=404,
            detail="Public 3D showcase is unavailable.",
        )

    asset = db.query(Product3DAsset).filter(
        Product3DAsset.id == model_id,
        Product3DAsset.product_id == product_id,
        Product3DAsset.is_active.is_(True),
        Product3DAsset.storage_bucket == BUCKET,
        Product3DAsset.model_format == "glb",
    ).first()

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
    """Upload an (already optimised) GLB to private storage + register it."""
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

    asset = Product3DAsset(
        product_id=product_id,
        display_name=display_name,
        variant_name=variant_name or None,
        storage_bucket=BUCKET,
        storage_path=storage_path,
        model_format="glb",
        file_size_bytes=len(content),
        is_active=True,
    )

    try:
        db.add(asset)
        db.commit()
        db.refresh(asset)
    except Exception:
        db.rollback()
        logger.exception("DB registration failed for %s", storage_path)
        try:
            storage.remove([storage_path])
        except Exception:
            logger.exception("Failed to clean orphan GLB %s", storage_path)
        raise HTTPException(status_code=500, detail="GLB registration failed.")

    return asset


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
    product = db.query(Product.name).filter(Product.id == product_id).first()

    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")

    return Response(
        content=_poster_png(product.name or "3D Model"),
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get("/showcase")
def get_3d_showcase(
    response: Response,
    db: Session = Depends(get_db),
):
    """Public feed for the '3D' filter: products + their active models."""
    response.headers["Cache-Control"] = "public, max-age=30"

    assets = db.query(Product3DAsset).filter(
        Product3DAsset.is_active.is_(True),
        Product3DAsset.storage_bucket == BUCKET,
        Product3DAsset.model_format == "glb",
    ).order_by(Product3DAsset.id).all()

    by_product: dict[int, list[Product3DAsset]] = {}
    for asset in assets:
        by_product.setdefault(asset.product_id, []).append(asset)

    if not by_product:
        return {"count": 0, "items": []}

    products = db.query(Product).filter(
        Product.id.in_(list(by_product))
    ).all()

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
    rows = db.query(Product3DAsset, Product.name).join(
        Product, Product.id == Product3DAsset.product_id
    ).order_by(Product3DAsset.id.desc()).all()

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
    asset = db.get(Product3DAsset, model_id)

    if asset is None:
        raise HTTPException(status_code=404, detail="3D model not found.")

    path, bucket = asset.storage_path, asset.storage_bucket

    db.delete(asset)
    db.commit()

    with _signed_url_lock:
        _signed_url_cache.pop(model_id, None)

    try:
        _, client = _service_client()
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
    poster: UploadFile | None = File(None),
    db: Session = Depends(get_db),
    admin: User = Depends(get_current_admin_user),
):
    """
    One-step 3D upload: creates a store product (so it can be searched,
    filtered and bought) and attaches the optimised GLB to it.
    """
    name = name.strip()
    category = category.strip() or SHOWCASE_CATEGORY

    if not 1 <= len(name) <= 150:
        raise HTTPException(status_code=422, detail="Name must be 1-150 characters.")
    if not 0 < price <= 1_000_000:
        raise HTTPException(status_code=422, detail="Enter a valid price.")
    if len(variant_name.strip()) > 100:
        raise HTTPException(status_code=422, detail="Variant name too long.")

    content = _read_glb_upload(file)

    poster_url: str | None = None

    if poster is not None and poster.filename:
        try:
            from PIL import Image

            raw = poster.file.read(MAX_POSTER_BYTES + 1)
            if not raw or len(raw) > MAX_POSTER_BYTES:
                raise ValueError("size")

            with Image.open(io.BytesIO(raw)) as im:
                im = im.convert("RGB")
                im.thumbnail((1024, 1024))
                buf = io.BytesIO()
                im.save(buf, format="JPEG", quality=88, optimize=True)

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
            poster_url = bucket.get_public_url(poster_path)
        except HTTPException:
            raise
        except Exception:
            logger.exception("Poster upload failed; using generated poster.")
            poster_url = None
        finally:
            poster.file.close()

    product = Product(
        name=name,
        description=description.strip() or f"Interactive 3D model: {name}",
        price=price,
        image_url=poster_url or "",
        category=category,
        rating=0.0,
        reviews=0,
        is_featured=False,
        stock=50,
        fulfillment_type="IN_HOUSE",
        supplier_id="PENGUIN_DIRECT",
    )

    try:
        db.add(product)
        db.flush()

        if not poster_url:
            product.image_url = f"/api/premium-3d/poster/{product.id}.png"

        db.commit()
        db.refresh(product)
    except Exception:
        db.rollback()
        logger.exception("Failed creating 3D product")
        raise HTTPException(status_code=500, detail="Could not create product.")

    try:
        asset = _store_glb(
            db,
            product.id,
            content,
            display_name=f"{name} 3D View"[:150],
            variant_name=variant_name.strip() or None,
        )
    except HTTPException:
        # Do not leave a model-less product behind.
        try:
            db.delete(product)
            db.commit()
        except Exception:
            db.rollback()
        raise

    return {
        "product_id": product.id,
        "model_id": asset.id,
        "name": product.name,
        "category": product.category,
        "image_url": product.image_url,
        "file_size_bytes": asset.file_size_bytes,
        "is_active": True,
    }
