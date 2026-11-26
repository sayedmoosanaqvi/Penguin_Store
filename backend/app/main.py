import asyncio
import logging
import os
import re
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    File,
    HTTPException,
    Request,
    UploadFile,
    status,
)
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse, ORJSONResponse
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session, load_only
from starlette.concurrency import run_in_threadpool
from supabase import Client, create_client

_BACKEND_ENV_PATH = Path(__file__).resolve().parents[1] / ".env"
load_dotenv(_BACKEND_ENV_PATH)
load_dotenv()

from . import models, schemas  # noqa: E402
from .api.v1.router import api_v1_router  # noqa: E402
from .core.config import settings  # noqa: E402
from .core.database import engine, get_db  # noqa: E402
from .core.security import (  # noqa: E402
    create_access_token,
    get_current_user,
    get_password_hash,
    require_role,
    resolve_user_role,
    verify_password,
)
from .middleware.security import (  # noqa: E402
    configure_cors,
    security_and_rate_limit_middleware,
)
from .models import CartItemModel, User  # noqa: E402
from .repositories.product_repo import PRODUCT_PUBLIC_COLUMNS  # noqa: E402
from .routers import (  # noqa: E402
    agent,
    agent_chat,
    mcp_server,
    notifications,
    orders,
    premium_3d,
    recommendations,
    stripe,
    supplier,
    trending,
    visual_search,
    voice_ai,
)

logger = logging.getLogger(__name__)

ENVIRONMENT = settings.ENVIRONMENT
FRONTEND_URL = settings.FRONTEND_URL
SUPABASE_URL = settings.SUPABASE_URL
SUPABASE_KEY = settings.SUPABASE_SERVICE_KEY
PUBLIC_ASSET_BUCKET = settings.PUBLIC_ASSET_BUCKET
PRIVATE_3D_BUCKET = settings.PRIVATE_3D_BUCKET
MAX_UPLOAD_BYTES = settings.MAX_UPLOAD_BYTES

ALLOWED_IMAGE_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".avif": "image/avif",
}

if not SUPABASE_URL or not SUPABASE_KEY:
    raise RuntimeError(
        "Supabase credentials are missing. "
        "Configure SUPABASE_URL and SUPABASE_SERVICE_KEY."
    )

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)


async def _warmup_ai_engines() -> None:
    """Pre-load Supabase HTTPS cache, ResNet-50 ONNX, and RAG chunks asynchronously."""
    try:
        from .core.supabase_rest import (
            fetch_3d_showcase_https,
            fetch_products_https,
        )

        await run_in_threadpool(fetch_products_https)
        await run_in_threadpool(fetch_3d_showcase_https)
        logger.info("Supabase HTTPS catalog & 3D showcase cache warmed up.")
    except Exception:
        logger.debug("Supabase HTTPS cache warmup deferred.", exc_info=True)

    try:
        from .agent.rag import load_knowledge_chunks
        from .vector_service import warmup_vision_model

        await run_in_threadpool(load_knowledge_chunks)
        await run_in_threadpool(warmup_vision_model)
        logger.info("AI engines warmed up at startup.")
    except Exception:
        logger.debug("AI startup warmup skipped or deferred.", exc_info=True)


@asynccontextmanager
async def app_lifespan(_app: FastAPI):
    warmup_task = asyncio.create_task(_warmup_ai_engines())
    try:
        yield
    finally:
        if not warmup_task.done():
            warmup_task.cancel()


app = FastAPI(
    title="Penguin Store API",
    description=(
        "Enterprise AI-powered e-commerce platform with strict RBAC, "
        "Supabase PostgreSQL + Storage, visual search, CTRL-X agents, and Premium 3D."
    ),
    version="2.2.0",
    lifespan=app_lifespan,
    default_response_class=ORJSONResponse,
)

configure_cors(app)
app.add_middleware(GZipMiddleware, minimum_size=500)
app.middleware("http")(security_and_rate_limit_middleware)


@app.exception_handler(Exception)
async def global_exception_handler(_request: Request, exc: Exception):
    logger.exception("Unhandled server exception: %s", exc)
    return JSONResponse(
        status_code=500,
        content={"detail": "An unexpected error occurred. Please try again shortly."},
    )


# Versioned & existing routers
app.include_router(api_v1_router)
app.include_router(agent.router)
app.include_router(stripe.router)
app.include_router(agent_chat.router)
app.include_router(supplier.router)
app.include_router(orders.router)
app.include_router(trending.router)
app.include_router(recommendations.router)
app.include_router(notifications.router)
app.include_router(visual_search.router)
app.include_router(voice_ai.router)
app.include_router(premium_3d.router)
app.include_router(mcp_server.router)


@app.get("/")
async def read_root():
    return {
        "message": "Welcome to Penguin Store API!",
        "status": "online",
        "version": "2.1.0",
        "features": [
            "Product Catalog",
            "CTRL-X AI Agent",
            "Stripe Checkout",
            "Order Management",
            "Visual Search",
            "Recommendations",
            "Premium 3D Infrastructure",
        ],
    }


@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "service": "penguin-store-api",
    }


@app.get("/ready")
async def readiness_check():
    """Verify database / Supabase catalog reachability for zero-downtime probes."""
    from .core.supabase_rest import _get_all_products_cached

    try:
        products = await run_in_threadpool(_get_all_products_cached)
        return {
            "status": "ready",
            "service": "penguin-store-api",
            "catalog_cached_count": len(products),
        }
    except Exception:
        return JSONResponse(
            status_code=503,
            content={"status": "degraded", "service": "penguin-store-api"},
        )


class TrackEventRequest(BaseModel):
    action: str = Field(..., min_length=1, max_length=100)
    details: Any = None
    timestamp: str | None = Field(default=None, max_length=64)
    device: str | None = Field(default=None, max_length=100)


@app.post("/track")
def track_user_action(payload: TrackEventRequest):
    return {
        "status": "recorded",
        "action": payload.action[:100],
    }


def _run_product_read(db: Session, operation):
    for attempt in range(2):
        try:
            return operation()
        except OperationalError:
            db.rollback()
            if attempt == 0:
                logger.warning("Product read failed. Retrying once.")
                continue
            logger.exception("Product read failed after retry.")
            raise HTTPException(
                status_code=503,
                detail="The product database is temporarily unavailable. Please try again.",
            )


@app.post(
    "/products/",
    response_model=schemas.Product,
    status_code=status.HTTP_201_CREATED,
)
def create_product(
    product: schemas.ProductCreate,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    from .core.supabase_rest import (
        _normalize_product_dict,
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    try:
        client = get_supabase_client()
        res = client.table("products").insert(product.model_dump()).execute()
        rows = res.data or []
        if not rows:
            raise HTTPException(status_code=409, detail="Product could not be created.")
        invalidate_supabase_rest_cache()
        created = _normalize_product_dict(rows[0])
        return created
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=409, detail="Product could not be created.")


@app.get("/products/", response_model=list[schemas.Product])
async def get_products(
    search: str | None = None,
    q: str | None = None,
    category: str | None = None,
    min_price: float | None = None,
    max_price: float | None = None,
    only_3d: bool = False,
    sort: str | None = None,
    limit: int | None = None,
    offset: int = 0,
):
    from .core.supabase_rest import fetch_products_singleflight_async

    eff_search = search if (search and search.strip()) else q
    return await fetch_products_singleflight_async(
        limit=limit,
        offset=offset,
        category=category,
        search=eff_search,
        min_price=min_price,
        max_price=max_price,
        only_3d=only_3d,
        sort=sort,
    )


@app.get("/products/search", response_model=list[schemas.Product])
async def search_products_legacy(
    q: str | None = None,
    search: str | None = None,
    category: str | None = None,
    min_price: float | None = None,
    max_price: float | None = None,
    only_3d: bool = False,
    sort: str | None = None,
    limit: int = 60,
    offset: int = 0,
):
    from .core.supabase_rest import fetch_products_singleflight_async

    eff_query = q if (q and q.strip()) else search
    return await fetch_products_singleflight_async(
        search=eff_query,
        category=category,
        min_price=min_price,
        max_price=max_price,
        only_3d=only_3d,
        sort=sort,
        limit=limit,
        offset=offset,
    )


@app.get("/products/{product_id}", response_model=schemas.Product)
async def get_product_by_id(product_id: int):
    from .core.supabase_rest import fetch_product_by_id_singleflight_async

    product = await fetch_product_by_id_singleflight_async(product_id)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")
    return product


@app.delete("/products/{product_id}", status_code=status.HTTP_200_OK)
def delete_product(
    product_id: int,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    from .api.v1.endpoints.products import execute_product_deletion

    return execute_product_deletion(
        product_id=product_id,
        background_tasks=background_tasks,
        db=db,
    )


class UserCreate(BaseModel):
    email: str = Field(..., min_length=3, max_length=254)
    password: str = Field(..., min_length=8, max_length=72)


@app.post("/signup", status_code=status.HTTP_201_CREATED)
def create_user(
    user: UserCreate,
    db: Session = Depends(get_db),
):
    email = user.email.strip().lower()
    password = user.password

    if len(email) > 254 or not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", email):
        raise HTTPException(status_code=422, detail="Enter a valid email address.")

    password_bytes = password.encode("utf-8")
    if len(password) < 8:
        raise HTTPException(
            status_code=422,
            detail="Password must contain at least 8 characters.",
        )
    if len(password_bytes) > 72:
        raise HTTPException(
            status_code=422,
            detail="Password exceeds the supported length.",
        )

    existing_user = (
        db.query(User.id)
        .filter(func.lower(User.email) == email)
        .first()
    )
    if existing_user:
        raise HTTPException(status_code=400, detail="Email already registered")

    new_user = User(
        email=email,
        hashed_password=get_password_hash(password),
        is_admin=False,
        role="customer",
        is_active=True,
    )

    try:
        db.add(new_user)
        db.commit()
        db.refresh(new_user)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=400, detail="Email already registered")

    return {"message": "User created successfully. Welcome to Penguin Store!"}


@app.post("/login")
def login(
    form_data: OAuth2PasswordRequestForm = Depends(),
    db: Session = Depends(get_db),
):
    from .core.security import _lookup_active_user

    email = form_data.username.strip().lower()
    user = _lookup_active_user(db, email)

    if (
        not user
        or not getattr(user, "is_active", True)
        or not verify_password(form_data.password, user.hashed_password)
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    role = resolve_user_role(user)
    access_token = create_access_token(
        data={
            "sub": user.email,
            "is_admin": bool(user.is_admin or role == "admin"),
            "role": role,
        }
    )

    return {
        "access_token": access_token,
        "token_type": "bearer",
        "role": role,
    }


@app.get("/auth/me")
def get_my_account(current_user: User = Depends(get_current_user)):
    role = resolve_user_role(current_user)
    return {
        "id": current_user.id,
        "email": current_user.email,
        "full_name": getattr(current_user, "full_name", None),
        "is_admin": bool(current_user.is_admin or role == "admin"),
        "role": role,
    }


@app.delete("/auth/me", status_code=status.HTTP_200_OK)
def delete_my_account_legacy_path(
    payload: schemas.DeleteAccountRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    from .api.v1.endpoints.auth import delete_my_account

    return delete_my_account(payload=payload, current_user=current_user, db=db)


def _normalize_studio_image(raw_bytes: bytes, ext: str) -> tuple[bytes, str, str]:
    """Center-fits an uploaded product image onto an 800x800 studio square canvas,
    trims noisy outer borders, and optimizes file size using Pillow (PIL).
    """
    if ext == ".gif":
        return raw_bytes, ext, ALLOWED_IMAGE_TYPES[ext]
    try:
        import io
        from PIL import Image, ImageChops, ImageOps

        with Image.open(io.BytesIO(raw_bytes)) as im:
            im = ImageOps.exif_transpose(im)
            has_alpha = im.mode in ("RGBA", "LA") or (
                im.mode == "P" and "transparency" in im.info
            )
            rgba = im.convert("RGBA")

            # Trim uniform solid outer borders if present
            if has_alpha:
                alpha_bbox = rgba.getchannel("A").getbbox()
                if alpha_bbox:
                    rgba = rgba.crop(alpha_bbox)
            else:
                bg_sample = Image.new("RGBA", rgba.size, rgba.getpixel((0, 0)))
                diff = ImageChops.difference(rgba, bg_sample).convert("L")
                bbox = diff.point(lambda p: 255 if p > 12 else 0).getbbox()
                if bbox:
                    bw = bbox[2] - bbox[0]
                    bh = bbox[3] - bbox[1]
                    if bw >= rgba.width * 0.25 and bh >= rgba.height * 0.25:
                        rgba = rgba.crop(bbox)

            canvas_size = 800
            inner_max = 704  # 48px clean studio margin on each side
            rgba.thumbnail((inner_max, inner_max), Image.Resampling.LANCZOS)

            if has_alpha:
                canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
            else:
                canvas = Image.new(
                    "RGBA", (canvas_size, canvas_size), (255, 255, 255, 255)
                )

            offset_x = (canvas_size - rgba.width) // 2
            offset_y = (canvas_size - rgba.height) // 2
            canvas.paste(rgba, (offset_x, offset_y), rgba)

            out = io.BytesIO()
            canvas.save(out, format="WEBP", quality=82)
            return out.getvalue(), ".webp", "image/webp"
    except Exception:
        logger.debug("Pillow studio normalization fallback to original bytes.", exc_info=True)
        return raw_bytes, ext, ALLOWED_IMAGE_TYPES[ext]


@app.post("/upload-file/")
async def upload_file_to_supabase(
    file: UploadFile = File(...),
    admin_user: User = Depends(require_role(["admin"])),
):
    import gc
    from .core.upload_security import validate_image_upload

    try:
        if not file.filename:
            raise HTTPException(status_code=400, detail="Filename is missing.")

        extension = os.path.splitext(file.filename)[1].lower()
        if extension not in ALLOWED_IMAGE_TYPES:
            raise HTTPException(
                status_code=415,
                detail="Unsupported image format. Use JPG, PNG, WEBP, GIF or AVIF.",
            )

        file_bytes = await file.read(MAX_UPLOAD_BYTES + 1)
        detected_ext, _ = validate_image_upload(
            file_bytes,
            file.filename,
            max_bytes=MAX_UPLOAD_BYTES,
            require_extension=True,
        )

        norm_bytes, norm_ext, content_type = await run_in_threadpool(
            _normalize_studio_image,
            file_bytes,
            detected_ext,
        )
        del file_bytes
        gc.collect()

        unique_filename = f"{uuid.uuid4().hex}{norm_ext}"

        def _upload_and_get_url() -> str:
            supabase.storage.from_(PUBLIC_ASSET_BUCKET).upload(
                path=unique_filename,
                file=norm_bytes,
                file_options={
                    "content-type": content_type,
                    "upsert": "false",
                },
            )
            return supabase.storage.from_(PUBLIC_ASSET_BUCKET).get_public_url(
                unique_filename
            )

        file_url = await run_in_threadpool(_upload_and_get_url)

        return {
            "url": file_url,
            "storage": "supabase",
            "bucket": PUBLIC_ASSET_BUCKET,
        }
    except HTTPException:
        raise
    except Exception:
        logger.exception("Supabase image upload failed.")
        raise HTTPException(
            status_code=500,
            detail="Failed to upload file to Supabase Storage.",
        )
    finally:
        await file.close()


# ===========================================================================
# /api/v1 ORDERS & PERSISTENT POSTGRESQL CART COMPATIBILITY ROUTES
# ===========================================================================

app.add_api_route(
    "/api/v1/orders/",
    orders.process_checkout,
    methods=["POST"],
    tags=["API v1"],
)
app.add_api_route(
    "/api/v1/orders/history/{customer_email}",
    orders.get_order_history,
    methods=["GET"],
    tags=["API v1"],
)


@app.get("/api/v1/cart/", tags=["API v1"])
def get_v1_cart(
    current_user: User = Depends(get_current_user),
):
    from .core.supabase_rest import fetch_product_by_id_https, get_supabase_client

    client = get_supabase_client()
    res = (
        client.table("cart_items")
        .select("product_id,quantity,selected_variant")
        .eq("user_id", current_user.id)
        .execute()
    )
    rows = res.data or []
    if not rows:
        return {
            "user_email": current_user.email.strip().lower(),
            "items": [],
            "subtotal": 0.0,
        }

    items_out = []
    subtotal = 0.0
    for row in rows:
        pid = int(row.get("product_id") or 0)
        p = fetch_product_by_id_https(pid)
        if not p:
            continue
        qty = int(row.get("quantity") or 1)
        price_val = float(p.get("price") or 0.0)
        line_total = round(price_val * qty, 2)
        subtotal += line_total
        items_out.append(
            {
                "product_id": pid,
                "name": p.get("name") or f"Product #{pid}",
                "price": price_val,
                "image_url": p.get("image_url") or "",
                "category": p.get("category") or "CATALOG",
                "stock": int(p.get("stock") if p.get("stock") is not None else 50),
                "quantity": qty,
                "selected_variant": row.get("selected_variant") or "",
                "line_total": line_total,
            }
        )

    return {
        "user_email": current_user.email.strip().lower(),
        "items": items_out,
        "subtotal": round(subtotal, 2),
    }


@app.post("/api/v1/cart/", tags=["API v1"])
def add_to_v1_cart(
    item: schemas.CartSyncItem,
    current_user: User = Depends(get_current_user),
):
    from .core.supabase_rest import upsert_cart_item_atomic_sync

    return upsert_cart_item_atomic_sync(
        user_id=current_user.id,
        product_id=item.product_id,
        quantity=item.quantity,
        selected_variant=item.selected_variant.strip(),
        mode="increment",
    )


@app.delete("/api/v1/cart/{product_id}", tags=["API v1"])
def remove_from_v1_cart(
    product_id: int,
    selected_variant: str = "",
    current_user: User = Depends(get_current_user),
):
    from .core.supabase_rest import get_supabase_client

    client = get_supabase_client()
    q = client.table("cart_items").delete().eq("user_id", current_user.id).eq("product_id", int(product_id))
    if selected_variant:
        q = q.eq("selected_variant", selected_variant.strip())
    q.execute()
    return {"status": "removed", "product_id": int(product_id)}


@app.put("/api/v1/cart/sync", tags=["API v1"])
def replace_v1_cart(
    payload: schemas.CartBulkSyncRequest,
    current_user: User = Depends(get_current_user),
):
    from datetime import datetime, timezone
    from .core.concurrency import KeyedLockPool
    from .core.supabase_rest import fetch_live_product_row_https, get_supabase_client

    global _BULK_CART_SYNC_LOCKS
    try:
        locks = _BULK_CART_SYNC_LOCKS
    except NameError:
        _BULK_CART_SYNC_LOCKS = KeyedLockPool(64)
        locks = _BULK_CART_SYNC_LOCKS

    merged: dict[tuple[int, str], int] = {}
    for entry in payload.items:
        prod = fetch_live_product_row_https(entry.product_id)
        if prod is None:
            continue
        avail = int(prod.get("stock") if prod.get("stock") is not None else 50)
        if avail <= 0:
            continue
        key = (entry.product_id, entry.selected_variant.strip()[:100])
        merged[key] = min(100, avail, merged.get(key, 0) + entry.quantity)

    now_iso = datetime.now(timezone.utc).isoformat()
    client = get_supabase_client()
    with locks.for_key(current_user.id):
        client.table("cart_items").delete().eq("user_id", current_user.id).execute()
        if merged:
            batch = [
                {
                    "user_id": current_user.id,
                    "product_id": pid,
                    "quantity": qty,
                    "selected_variant": variant,
                    "updated_at": now_iso,
                }
                for (pid, variant), qty in merged.items()
            ]
            client.table("cart_items").upsert(
                batch,
                on_conflict="user_id,product_id,selected_variant",
            ).execute()
    return {"status": "synced", "item_count": len(merged)}
