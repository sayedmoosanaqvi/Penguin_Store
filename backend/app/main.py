from fastapi import FastAPI, Depends, HTTPException, status, UploadFile, File
from sqlalchemy.orm import Session
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel
import os
import uuid
import boto3
from dotenv import load_dotenv

from . import models, schemas
from .database import engine, get_db
from .security import get_password_hash, verify_password, create_access_token
from .models import User
from .routers import agent

# This loads your secret keys from the .env file so Python can use them safely
load_dotenv()

# Initialize the AWS S3 Client
s3_client = boto3.client(
    's3',
    aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
    aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
    region_name=os.getenv("AWS_REGION")
)

AWS_BUCKET_NAME = os.getenv("AWS_BUCKET_NAME")
AWS_REGION = os.getenv("AWS_REGION")
print("🔥🔥🔥 DEBUG BUCKET NAME IS:", AWS_BUCKET_NAME)

# Create the database tables
models.Base.metadata.create_all(bind=engine)

app = FastAPI(title="Penguin Store API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # Allows all connections (perfect for development)
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(agent.router)

@app.get("/")
def read_root():
    return {"message": "Penguin Store Backend is running."}

@app.get("/")
def read_root():
    return {"message": "Welcome to the Penguin Store API! The engine is running."}

# --- PRODUCT ROUTES ---

# 1. CREATE A PRODUCT (Admin Upload)
@app.post("/products/", response_model=schemas.Product)
def create_product(product: schemas.ProductCreate, db: Session = Depends(get_db)):
    # Convert the Pydantic schema into a SQLAlchemy model
    db_product = models.Product(**product.model_dump())
    # Add it to the database
    db.add(db_product)
    db.commit()
    db.refresh(db_product)
    return db_product

# 2. GET ALL PRODUCTS (For your Flutter Home Screen)
@app.get("/products/", response_model=list[schemas.Product])
def get_products(db: Session = Depends(get_db)):
    # Fetch all products from the database
    products = db.query(models.Product).all()
    return products

@app.delete("/products/{product_id}", status_code=status.HTTP_200_OK)
def delete_product(product_id: int, db: Session = Depends(get_db)):
    # 1. Find the product in the database
    product_query = db.query(models.Product).filter(models.Product.id == product_id)
    product = product_query.first()

    # 2. Check if it exists
    if product == None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Product with id: {product_id} does not exist")

    # 3. Delete and commit the change
    product_query.delete(synchronize_session=False)
    db.commit()
    
    return {"message": "Product deleted successfully"}


# --- SCHEMAS ---
class UserCreate(BaseModel):
    email: str
    password: str

# --- AUTHENTICATION ROUTES ---

@app.post("/signup", status_code=status.HTTP_201_CREATED)
def create_user(user: UserCreate, db: Session = Depends(get_db)):
    db_user = db.query(User).filter(User.email == user.email).first()
    if db_user:
        raise HTTPException(status_code=400, detail="Email already registered")
    
    hashed_password = get_password_hash(user.password)
    
    # Explicitly set is_admin=False for safety
    new_user = User(email=user.email, hashed_password=hashed_password, is_admin=False)
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    
    return {"message": "User created successfully. Welcome to Penguin Store!"}

# --- ONLY ONE LOGIN ROUTE ---
@app.post("/login")
def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    # 1. THE MASTER ADMIN BYPASS (Check this first)
    if form_data.username == "admin@penguin.com" and form_data.password == "Penguin123456":
        admin_user = db.query(User).filter(User.email == "admin@penguin.com").first()
        
        # Auto-create admin if missing
        if not admin_user:
            hashed_pw = get_password_hash("Penguin123456")
            admin_user = User(email="admin@penguin.com", hashed_password=hashed_pw, is_admin=True)
            db.add(admin_user)
            db.commit()
            db.refresh(admin_user)
        
        access_token = create_access_token(data={"sub": admin_user.email, "is_admin": True})
        return {"access_token": access_token, "token_type": "bearer"}

    # 2. NORMAL CUSTOMER LOGIC
    user = db.query(User).filter(User.email == form_data.username).first()
    
    if not user or not verify_password(form_data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # Notice we include user.is_admin from the database!
    access_token = create_access_token(
        data={"sub": user.email, "is_admin": user.is_admin}
    )
    
    return {"access_token": access_token, "token_type": "bearer"}

@app.post("/upload-file/")
async def upload_file_to_s3(file: UploadFile = File(...)):
    try:
        # 1. Generate a random, unique name so files don't overwrite each other
        file_extension = file.filename.split(".")[-1]
        unique_filename = f"{uuid.uuid4()}.{file_extension}"
        
        # 2. Upload the file to your AWS S3 Bucket
        s3_client.upload_fileobj(
            file.file,
            AWS_BUCKET_NAME,
            unique_filename,
            ExtraArgs={
                "ContentType": file.content_type  # CRITICAL for 3D files!
            }
        )
        
        # 3. Construct the permanent public URL
        file_url = f"https://{AWS_BUCKET_NAME}.s3.{AWS_REGION}.amazonaws.com/{unique_filename}"
        
        # Return the URL so Flutter can save it to your database
        return {"url": file_url}

    except Exception as e:
        print(f"AWS Upload Error: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, 
            detail="Failed to upload file to cloud storage"
        )