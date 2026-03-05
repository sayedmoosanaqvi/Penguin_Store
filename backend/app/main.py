from fastapi import FastAPI, Depends, HTTPException
from sqlalchemy.orm import Session
from . import models, schemas
from .database import engine, get_db
from fastapi.middleware.cors import CORSMiddleware
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordRequestForm
from pydantic import BaseModel
from .security import get_password_hash, verify_password, create_access_token
# Ensure you are importing your User model alongside Product
from .models import User

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

# --- SCHEMAS ---
class UserCreate(BaseModel):
    email: str
    password: str

# --- AUTHENTICATION ROUTES ---

@app.post("/signup", status_code=status.HTTP_201_CREATED)
def create_user(user: UserCreate, db: Session = Depends(get_db)):
    # 1. Check if the email is already in the database
    db_user = db.query(User).filter(User.email == user.email).first()
    if db_user:
        raise HTTPException(status_code=400, detail="Email already registered")
    
    # 2. Scramble the password using your security engine
    hashed_password = get_password_hash(user.password)
    
    # 3. Save the new user to PostgreSQL
    new_user = User(email=user.email, hashed_password=hashed_password)
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    
    return {"message": "User created successfully. Welcome to Penguin Store!"}
@app.post("/login")
def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    
    # --- 1. THE MASTER ADMIN BYPASS ---
    if form_data.username == "admin@penguin.com" and form_data.password == "Penguin123456":
        # Check if the admin is already in the database
        admin_user = db.query(User).filter(User.email == "admin@penguin.com").first()
        
        # If the admin doesn't exist yet, create them automatically!
        if not admin_user:
            hashed_pw = get_password_hash("Penguin123456")
            admin_user = User(email="admin@penguin.com", hashed_password=hashed_pw, is_admin=True)
            db.add(admin_user)
            db.commit()
            db.refresh(admin_user)
        
        # Issue the special Admin JWT Token
        access_token = create_access_token(data={"sub": admin_user.email, "is_admin": True})
        return {"access_token": access_token, "token_type": "bearer"}
    # ----------------------------------

    # --- 2. NORMAL CUSTOMER LOGIC ---
    # Find the regular user by email
    user = db.query(User).filter(User.email == form_data.username).first()
    
    # Check if user exists AND if the password matches the hash
    if not user or not verify_password(form_data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # If successful, generate the standard JWT token
    access_token = create_access_token(
        data={"sub": user.email, "is_admin": user.is_admin}
    )
    
    return {"access_token": access_token, "token_type": "bearer"}


@app.post("/login")
def login(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    # OAuth2PasswordRequestForm expects 'username' and 'password' from the frontend
    # We use 'username' to store the email here.
    
    # 1. Find the user by email
    user = db.query(User).filter(User.email == form_data.username).first()
    
    # 2. Check if user exists AND if the password matches the hash
    if not user or not verify_password(form_data.password, user.hashed_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    # 3. If successful, generate the JWT token. 
    # Notice we pack the 'is_admin' flag inside the token payload!
    access_token = create_access_token(
        data={"sub": user.email, "is_admin": user.is_admin}
    )
    
    # 4. Return the token to Flutter
    return {"access_token": access_token, "token_type": "bearer"}

    