import bcrypt
from datetime import datetime, timedelta
from jose import jwt
from fastapi import Security, HTTPException, status
from fastapi.security import APIKeyHeader

# --- 1. NEW BCRYPT HASHING LOGIC (No Passlib) ---

def verify_password(plain_password: str, hashed_password: str) -> bool:
    # bcrypt requires bytes, so we encode the strings to utf-8 first
    return bcrypt.checkpw(plain_password.encode('utf-8'), hashed_password.encode('utf-8'))

def get_password_hash(password: str) -> str:
    # Generate a secure salt and hash the password
    salt = bcrypt.gensalt()
    hashed_bytes = bcrypt.hashpw(password.encode('utf-8'), salt)
    # Convert the bytes back into a string so PostgreSQL can save it smoothly
    return hashed_bytes.decode('utf-8')


# --- 2. YOUR EXISTING JWT LOGIC ---

# In a production app, this should be a long random string hidden in a .env file
SECRET_KEY = "penguin_store_super_secret_key" 
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24 * 7 # Token stays valid for 7 days

def create_access_token(data: dict):
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    
    # This creates the secure, scrambled JWT string
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

   

# 🛑 This is the key you will give to your partner! 
# In a real app, put this in a .env file. For now, hardcode it to test.
AGENT_API_KEY = "ctrl_x_alpha_key_2026" 
api_key_header = APIKeyHeader(name="X-Agent-Key", auto_error=True)

async def verify_agent(api_key: str = Security(api_key_header)):
    if api_key != AGENT_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, 
            detail="Access Denied: Invalid CTRL-X Agent Key"
        )
    return api_key