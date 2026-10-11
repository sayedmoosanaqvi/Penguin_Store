
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

from ..database import get_db
from ..models import PremiumSubscription, Product, Product3DAsset, User
from ..security import get_current_admin_user, get_current_user

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/premium-3d",
    tags=["Premium 3D"],
)

BUCKET = "penguin-store-3d"
SIGNED_URL_LIFETIME = 300
MAX_GLB_BYTES = 20 * 1024 * 1024

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
                "and at most 20 MB."
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

