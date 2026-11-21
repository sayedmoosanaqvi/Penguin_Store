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
from fastapi.responses import JSONResponse
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
    notifications,
    orders,
    premium_3d,
    recommendations,
    stripe,
    supplier,
    trending,
    visual_search,
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
    version="2.1.0",
    lifespan=app_lifespan,
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
app.include_router(premium_3d.router)


@app.get("/")
def read_root():
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
def health_check():
    return {
        "status": "healthy",
        "service": "penguin-store-api",
    }


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
def get_products(db: Session = Depends(get_db)):
    from .core.supabase_rest import (
        fetch_products_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        return fetch_products_https()

    def query_products():
        return (
            db.query(models.Product)
            .options(load_only(*PRODUCT_PUBLIC_COLUMNS))
            .order_by(models.Product.id.asc())
            .all()
        )

    try:
        return _run_product_read(db, query_products)
    except HTTPException:
        mark_pg_tcp_unreachable()
        return fetch_products_https()


@app.get("/products/{product_id}", response_model=schemas.Product)
def get_product_by_id(product_id: int, db: Session = Depends(get_db)):
    from .core.supabase_rest import (
        fetch_product_by_id_https,
        is_pg_tcp_reachable,
        mark_pg_tcp_unreachable,
    )

    if not is_pg_tcp_reachable():
        product = fetch_product_by_id_https(product_id)
        if product is None:
            raise HTTPException(status_code=404, detail="Product not found.")
        return product

    def query_product():
        return (
            db.query(models.Product)
            .options(load_only(*PRODUCT_PUBLIC_COLUMNS))
            .filter(models.Product.id == product_id)
            .first()
        )

    try:
        product = _run_product_read(db, query_product)
    except HTTPException:
        mark_pg_tcp_unreachable()
        product = fetch_product_by_id_https(product_id)

    if product is None:
        raise HTTPException(status_code=404, detail="Product not found.")
    return product


@app.delete("/products/{product_id}", status_code=status.HTTP_200_OK)
def delete_product(
    product_id: int,
    db: Session = Depends(get_db),
    admin_user: User = Depends(require_role(["admin"])),
):
    from .core.supabase_rest import (
        fetch_product_by_id_https,
        get_supabase_client,
        invalidate_supabase_rest_cache,
    )

    if product_id == 144:
        raise HTTPException(
            status_code=403,
            detail="Product #144 is protected as the reference 3D showcase asset.",
        )

    existing = fetch_product_by_id_https(product_id)
    if existing is None:
        raise HTTPException(
            status_code=404,
            detail=f"Product with id {product_id} does not exist.",
        )

    try:
        client = get_supabase_client()
        client.table("product_3d_assets").delete().eq("product_id", product_id).execute()
        client.table("products").delete().eq("id", product_id).execute()
        invalidate_supabase_rest_cache()
        visual_search.invalidate_visual_cache()
    except Exception:
        raise HTTPException(
            status_code=409,
            detail="This product is referenced by existing records and cannot be deleted.",
        )

    return {"message": "Product deleted successfully"}


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
                    "RGBA", (canvas_size, canvas_size), (248, 250, 252, 255)
                )

            offset_x = (canvas_size - rgba.width) // 2
            offset_y = (canvas_size - rgba.height) // 2
            canvas.paste(rgba, (offset_x, offset_y), rgba)

            out = io.BytesIO()
            canvas.save(out, format="PNG", optimize=True)
            return out.getvalue(), ".png", "image/png"
    except Exception:
        logger.debug("Pillow studio normalization fallback to original bytes.", exc_info=True)
        return raw_bytes, ext, ALLOWED_IMAGE_TYPES[ext]


@app.post("/upload-file/")
async def upload_file_to_supabase(
    file: UploadFile = File(...),
    admin_user: User = Depends(require_role(["admin"])),
):
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
        if not file_bytes:
            raise HTTPException(status_code=400, detail="Uploaded file is empty.")
        if len(file_bytes) > MAX_UPLOAD_BYTES:
            raise HTTPException(
                status_code=413,
                detail="Image exceeds the 10 MB upload limit.",
            )

        norm_bytes, norm_ext, content_type = await run_in_threadpool(
            _normalize_studio_image,
            file_bytes,
            extension,
        )
        unique_filename = f"{uuid.uuid4().hex}{norm_ext}"

        supabase.storage.from_(PUBLIC_ASSET_BUCKET).upload(
            path=unique_filename,
            file=norm_bytes,
            file_options={
                "content-type": content_type,
                "upsert": "false",
            },
        )

        file_url = supabase.storage.from_(PUBLIC_ASSET_BUCKET).get_public_url(
            unique_filename
        )

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
    db: Session = Depends(get_db),
):
    rows = (
        db.query(CartItemModel)
        .filter(CartItemModel.user_id == current_user.id)
        .all()
    )
    if not rows:
        return {
            "user_email": current_user.email.strip().lower(),
            "items": [],
            "subtotal": 0.0,
        }

    pids = [r.product_id for r in rows]
    products = (
        db.query(models.Product)
        .options(load_only(*PRODUCT_PUBLIC_COLUMNS))
        .filter(models.Product.id.in_(pids))
        .all()
    )
    by_id = {p.id: p for p in products}

    items_out = []
    subtotal = 0.0
    for row in rows:
        p = by_id.get(row.product_id)
        if not p:
            continue
        line_total = round(float(p.price) * row.quantity, 2)
        subtotal += line_total
        items_out.append(
            {
                "product_id": p.id,
                "name": p.name,
                "price": float(p.price),
                "image_url": p.image_url,
                "category": p.category,
                "quantity": row.quantity,
                "selected_variant": row.selected_variant,
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
    db: Session = Depends(get_db),
):
    product = (
        db.query(models.Product)
        .options(load_only(models.Product.id, models.Product.name, models.Product.stock))
        .filter(models.Product.id == item.product_id)
        .first()
    )
    if not product:
        raise HTTPException(status_code=404, detail="Product not found.")

    variant = item.selected_variant.strip()
    existing = (
        db.query(CartItemModel)
        .filter(
            CartItemModel.user_id == current_user.id,
            CartItemModel.product_id == item.product_id,
            CartItemModel.selected_variant == variant,
        )
        .first()
    )

    if existing:
        existing.quantity = min(100, existing.quantity + item.quantity)
        new_qty = existing.quantity
    else:
        db.add(
            CartItemModel(
                user_id=current_user.id,
                product_id=item.product_id,
                quantity=item.quantity,
                selected_variant=variant,
            )
        )
        new_qty = item.quantity

    db.commit()
    return {
        "status": "added",
        "product_id": item.product_id,
        "selected_variant": variant,
        "quantity": new_qty,
    }


@app.put("/api/v1/cart/sync", tags=["API v1"])
def replace_v1_cart(
    payload: schemas.CartBulkSyncRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    db.query(CartItemModel).filter(CartItemModel.user_id == current_user.id).delete()
    merged: dict[tuple[int, str], int] = {}
    for entry in payload.items:
        key = (entry.product_id, entry.selected_variant.strip())
        merged[key] = min(100, merged.get(key, 0) + entry.quantity)

    for (pid, variant), qty in merged.items():
        db.add(
            CartItemModel(
                user_id=current_user.id,
                product_id=pid,
                quantity=qty,
                selected_variant=variant,
            )
        )
    db.commit()
    return {"status": "synced", "item_count": len(merged)}
