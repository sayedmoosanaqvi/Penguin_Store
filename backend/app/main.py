
import os
import re
import uuid
import logging
from urllib.parse import urlsplit

from dotenv import load_dotenv
from supabase import create_client, Client

from fastapi import (
    FastAPI,
    Depends,
    HTTPException,
    UploadFile,
    File,
    status,
)

from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordRequestForm

from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlalchemy.orm import Session, load_only

from . import models, schemas
from .database import engine, get_db
from .models import User

from .security import (
    get_password_hash,
    verify_password,
    create_access_token,
    get_current_user,
    get_current_admin_user,
)

from .routers import (
    agent,
    stripe,
    agent_chat,
    supplier,
    orders,
    trending,
    recommendations,
    notifications,
    visual_search,
    premium_3d,
)


load_dotenv()

logger = logging.getLogger(__name__)

ENVIRONMENT = os.getenv(
    "ENVIRONMENT",
    "development",
).lower()

FRONTEND_URL = os.getenv(
    "FRONTEND_URL",
    "",
).strip()

SUPABASE_URL = os.getenv("SUPABASE_URL")

SUPABASE_KEY = (
    os.getenv("SUPABASE_SERVICE_KEY")
    or os.getenv("SUPABASE_KEY")
)

PUBLIC_ASSET_BUCKET = "penguin-store-assets"
PRIVATE_3D_BUCKET = "penguin-store-3d"

MAX_UPLOAD_BYTES = 10 * 1024 * 1024

ALLOWED_IMAGE_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".avif": "image/avif",
}


# Supabase client
if not SUPABASE_URL or not SUPABASE_KEY:
    raise RuntimeError(
        "Supabase credentials are missing. "
        "Configure SUPABASE_URL and SUPABASE_SERVICE_KEY."
    )

supabase: Client = create_client(
    SUPABASE_URL,
    SUPABASE_KEY,
)


# Database initialization
models.Base.metadata.create_all(bind=engine)


# FastAPI application
app = FastAPI(
    title="Penguin Store API",
    description=(
        "AI-powered e-commerce platform with "
        "secure authentication, product management, "
        "Stripe payments, visual search and Premium 3D."
    ),
    version="2.0.0",
)


# CORS configuration
allowed_origins = set()

if FRONTEND_URL:
    parsed_frontend = urlsplit(FRONTEND_URL)

    if (
        parsed_frontend.scheme in ("http", "https")
        and parsed_frontend.netloc
    ):
        allowed_origins.add(
            f"{parsed_frontend.scheme}://"
            f"{parsed_frontend.netloc}"
        )

for origin in os.getenv(
    "ALLOWED_ORIGINS",
    "",
).split(","):
    origin = origin.strip().rstrip("/")

    if origin:
        parsed_origin = urlsplit(origin)

        if (
            parsed_origin.scheme in ("http", "https")
            and parsed_origin.netloc
            and not parsed_origin.path
            and not parsed_origin.query
            and not parsed_origin.fragment
        ):
            allowed_origins.add(origin)

local_origin_regex = None

if ENVIRONMENT == "development":
    local_origin_regex = (
        r"^http://(localhost|127\.0\.0\.1)(:\d+)?$"
    )

app.add_middleware(
    CORSMiddleware,
    allow_origins=sorted(allowed_origins),
    allow_origin_regex=local_origin_regex,
    allow_credentials=True,
    allow_methods=[
        "GET",
        "POST",
        "PUT",
        "PATCH",
        "DELETE",
        "OPTIONS",
    ],
    allow_headers=["*"],
)


# Existing API routers
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


# Root endpoint
@app.get("/")
def read_root():
    return {
        "message": "Welcome to Penguin Store API!",
        "status": "online",
        "version": "2.0.0",
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


# Health endpoint
@app.get("/health")
def health_check():
    return {
        "status": "healthy",
        "service": "penguin-store-api",
    }


# Public product fields only
PRODUCT_PUBLIC_COLUMNS = (
    models.Product.id,
    models.Product.name,
    models.Product.description,
    models.Product.price,
    models.Product.original_price,
    models.Product.image_url,
    models.Product.category,
    models.Product.rating,
    models.Product.reviews,
    models.Product.discount_percent,
    models.Product.is_featured,
)


# Retry read-only queries after transient database disconnects
def _run_product_read(db: Session, operation):
    for attempt in range(2):
        try:
            return operation()

        except OperationalError:
            db.rollback()

            if attempt == 0:
                logger.warning(
                    "Product read failed. Retrying once."
                )
                continue

            logger.exception(
                "Product read failed after retry."
            )

            raise HTTPException(
                status_code=503,
                detail=(
                    "The product database is temporarily "
                    "unavailable. Please try again."
                ),
            )


# Product creation - admin only
@app.post(
    "/products/",
    response_model=schemas.Product,
    status_code=status.HTTP_201_CREATED,
)
def create_product(
    product: schemas.ProductCreate,
    db: Session = Depends(get_db),
    admin_user: User = Depends(get_current_admin_user),
):
    db_product = models.Product(
        **product.model_dump()
    )

    try:
        db.add(db_product)
        db.commit()
        db.refresh(db_product)

    except IntegrityError:
        db.rollback()

        raise HTTPException(
            status_code=409,
            detail="Product could not be created.",
        )

    return db_product


# Optimized product catalog - public
@app.get(
    "/products/",
    response_model=list[schemas.Product],
)
def get_products(
    db: Session = Depends(get_db),
):
    def query_products():
        return (
            db.query(models.Product)
            .options(
                load_only(
                    *PRODUCT_PUBLIC_COLUMNS
                )
            )
            .order_by(
                models.Product.id.asc()
            )
            .all()
        )

    return _run_product_read(
        db,
        query_products,
    )


# Optimized single-product endpoint
@app.get(
    "/products/{product_id}",
    response_model=schemas.Product,
)
def get_product_by_id(
    product_id: int,
    db: Session = Depends(get_db),
):
    def query_product():
        return (
            db.query(models.Product)
            .options(
                load_only(
                    *PRODUCT_PUBLIC_COLUMNS
                )
            )
            .filter(
                models.Product.id == product_id
            )
            .first()
        )

    product = _run_product_read(
        db,
        query_product,
    )

    if product is None:
        raise HTTPException(
            status_code=404,
            detail="Product not found.",
        )

    return product


# Product deletion - admin only
@app.delete(
    "/products/{product_id}",
    status_code=status.HTTP_200_OK,
)
def delete_product(
    product_id: int,
    db: Session = Depends(get_db),
    admin_user: User = Depends(get_current_admin_user),
):
    product = (
        db.query(models.Product)
        .filter(
            models.Product.id == product_id
        )
        .first()
    )

    if product is None:
        raise HTTPException(
            status_code=404,
            detail=(
                f"Product with id {product_id} "
                "does not exist."
            ),
        )

    try:
        db.delete(product)
        db.commit()

    except IntegrityError:
        db.rollback()

        raise HTTPException(
            status_code=409,
            detail=(
                "This product is referenced by existing "
                "records and cannot be deleted."
            ),
        )

    return {
        "message": "Product deleted successfully",
    }


# User registration schema
class UserCreate(BaseModel):
    email: str
    password: str


# User registration
@app.post(
    "/signup",
    status_code=status.HTTP_201_CREATED,
)
def create_user(
    user: UserCreate,
    db: Session = Depends(get_db),
):
    email = user.email.strip().lower()
    password = user.password

    if (
        len(email) > 254
        or not re.fullmatch(
            r"[^@\s]+@[^@\s]+\.[^@\s]+",
            email,
        )
    ):
        raise HTTPException(
            status_code=422,
            detail="Enter a valid email address.",
        )

    password_bytes = password.encode("utf-8")

    if len(password) < 8:
        raise HTTPException(
            status_code=422,
            detail=(
                "Password must contain at least "
                "8 characters."
            ),
        )

    if len(password_bytes) > 72:
        raise HTTPException(
            status_code=422,
            detail=(
                "Password exceeds the supported length."
            ),
        )

    existing_user = (
        db.query(User)
        .filter(
            func.lower(User.email) == email
        )
        .first()
    )

    if existing_user:
        raise HTTPException(
            status_code=400,
            detail="Email already registered",
        )

    hashed_password = get_password_hash(
        password
    )

    new_user = User(
        email=email,
        hashed_password=hashed_password,
        is_admin=False,
    )

    try:
        db.add(new_user)
        db.commit()
        db.refresh(new_user)

    except IntegrityError:
        db.rollback()

        raise HTTPException(
            status_code=400,
            detail="Email already registered",
        )

    return {
        "message": (
            "User created successfully. "
            "Welcome to Penguin Store!"
        )
    }


# Secure JWT login
@app.post("/login")
def login(
    form_data: OAuth2PasswordRequestForm = Depends(),
    db: Session = Depends(get_db),
):
    email = form_data.username.strip().lower()

    user = (
        db.query(User)
        .filter(
            func.lower(User.email) == email
        )
        .first()
    )

    if not user or not verify_password(
        form_data.password,
        user.hashed_password,
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={
                "WWW-Authenticate": "Bearer",
            },
        )

    access_token = create_access_token(
        data={
            "sub": user.email,
            "is_admin": bool(user.is_admin),
        }
    )

    return {
        "access_token": access_token,
        "token_type": "bearer",
    }


# Authenticated account details
@app.get("/auth/me")
def get_my_account(
    current_user: User = Depends(get_current_user),
):
    return {
        "id": current_user.id,
        "email": current_user.email,
        "is_admin": bool(current_user.is_admin),
    }


# Secure image upload to Supabase - admin only
@app.post("/upload-file/")
async def upload_file_to_supabase(
    file: UploadFile = File(...),
    admin_user: User = Depends(get_current_admin_user),
):
    try:
        if not file.filename:
            raise HTTPException(
                status_code=400,
                detail="Filename is missing.",
            )

        extension = os.path.splitext(
            file.filename
        )[1].lower()

        if extension not in ALLOWED_IMAGE_TYPES:
            raise HTTPException(
                status_code=415,
                detail=(
                    "Unsupported image format. "
                    "Use JPG, PNG, WEBP, GIF or AVIF."
                ),
            )

        file_bytes = await file.read(
            MAX_UPLOAD_BYTES + 1
        )

        if not file_bytes:
            raise HTTPException(
                status_code=400,
                detail="Uploaded file is empty.",
            )

        if len(file_bytes) > MAX_UPLOAD_BYTES:
            raise HTTPException(
                status_code=413,
                detail=(
                    "Image exceeds the 10 MB upload limit."
                ),
            )

        content_type = ALLOWED_IMAGE_TYPES[
            extension
        ]

        unique_filename = (
            f"{uuid.uuid4().hex}{extension}"
        )

        supabase.storage.from_(
            PUBLIC_ASSET_BUCKET
        ).upload(
            path=unique_filename,
            file=file_bytes,
            file_options={
                "content-type": content_type,
                "upsert": "false",
            },
        )

        file_url = (
            supabase.storage
            .from_(PUBLIC_ASSET_BUCKET)
            .get_public_url(
                unique_filename
            )
        )

        return {
            "url": file_url,
            "storage": "supabase",
            "bucket": PUBLIC_ASSET_BUCKET,
        }

    except HTTPException:
        raise

    except Exception:
        logger.exception(
            "Supabase image upload failed."
        )

        raise HTTPException(
            status_code=500,
            detail=(
                "Failed to upload file "
                "to Supabase Storage."
            ),
        )

    finally:
        await file.close()
