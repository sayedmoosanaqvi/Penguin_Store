from fastapi import APIRouter, UploadFile, File, Depends, HTTPException
from sqlalchemy.orm import Session
import numpy as np
import urllib.request

from app.database import get_db
from app.models import Product
from app.ml.vision_engine import extract_image_embedding

router = APIRouter(prefix="/api/search", tags=["Visual Search"])

def cosine_similarity(v1: list[float], v2: list[float]) -> float:
    a = np.array(v1)
    b = np.array(v2)
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))

@router.post("/visual")
async def visual_product_search(
    file: UploadFile = File(...),
    db: Session = Depends(get_db)
):
    """
    Accepts an uploaded image, extracts its MobileNetV3 feature vector,
    and returns products ranked by cosine similarity.
    """
    
    # Relaxed validation for Flutter Web generic byte streams
    # if not file.content_type.startswith("image/"):
    #     raise HTTPException(status_code=400, detail="File must be an image.")

    image_bytes = await file.read()
    query_vector_str = extract_image_embedding(image_bytes)

    if not query_vector_str:
        raise HTTPException(status_code=500, detail="Failed to process image features.")

    query_vector = [float(x) for x in query_vector_str.split(",")]

    # Query products that have precomputed visual embeddings
    products = db.query(Product).filter(Product.visual_embedding.isnot(None)).all()

    if not products:
        # Fallback: if no embeddings are indexed yet, return empty matches
        return {
            "query_status": "success",
            "matches": [],
            "message": "No indexed product embeddings found in database."
        }

    scored_products = []
    for product in products:
        try:
            prod_vector = [float(x) for x in product.visual_embedding.split(",")]
            score = cosine_similarity(query_vector, prod_vector)
            scored_products.append({
                "score": round(score, 4),
                "product": {
                    "id": product.id,
                    "name": product.name,
                    "price": product.price,
                    "image_url": product.image_url,
                    "category": product.category,
                    "stock": product.stock
                }
            })
        except Exception:
            continue

    # Rank products descending by highest visual similarity score
    scored_products.sort(key=lambda x: x["score"], reverse=True)

    return {
        "query_status": "success",
        "total_matches": len(scored_products),
        "matches": scored_products[:6]  # Return top 6 matches
    }

@router.post("/index-inventory")
def index_existing_products(db: Session = Depends(get_db)):
    """
    Loops through all products missing a vector, downloads their image, 
    and calculates the visual embedding for future searches.
    """
    # Find products that haven't been processed yet
    products = db.query(Product).filter(Product.visual_embedding.is_(None)).all()
    
    indexed_count = 0
    for product in products:
        if not product.image_url:
            continue
            
        try:
            # Fetch the image bytes directly from your S3 image_url
            req = urllib.request.Request(
                product.image_url, 
                headers={'User-Agent': 'Mozilla/5.0'}
            )
            with urllib.request.urlopen(req) as response:
                image_bytes = response.read()
            
            # Convert the raw image into a math vector
            vector_str = extract_image_embedding(image_bytes)
            
            if vector_str:
                product.visual_embedding = vector_str
                indexed_count += 1
                print(f"Indexed: {product.name}")
                
        except Exception as e:
            print(f"[INDEXING ERROR] Failed to process product ID {product.id}: {str(e)}")
            continue
            
    # Save all new vectors to the database
    db.commit()
    return {"message": f"Successfully generated visual embeddings for {indexed_count} products."}