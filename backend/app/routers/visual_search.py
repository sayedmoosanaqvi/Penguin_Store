import os
import urllib.request
from fastapi import APIRouter, UploadFile, File, HTTPException
from supabase import create_client, Client
from app.vector_service import generate_image_vector

# Keep your existing prefix and tags
router = APIRouter(prefix="/api/search", tags=["Visual Search"])

# Initialize Supabase Client to directly access the pgvector capabilities
supabase_url: str = os.getenv("SUPABASE_URL")
supabase_key: str = os.getenv("SUPABASE_KEY")
supabase: Client = create_client(supabase_url, supabase_key)


@router.post("/visual")
async def visual_product_search(file: UploadFile = File(...)):
    """
    Accepts an uploaded image, extracts its CLIP feature vector,
    and returns products ranked by cosine distance directly from Supabase.
    """
    try:
        image_bytes = await file.read()
        
        # 1. Generate the 512-dimension vector using the new CLIP model
        query_vector = generate_image_vector(image_bytes)
        
        # 2. Call the Supabase RPC function for lightning-fast database-level matching
        response = supabase.rpc(
            "match_products", 
            {"query_embedding": query_vector, "match_limit": 6}
        ).execute()

        # 3. Format the response to perfectly match your Flutter frontend's expected UI structure
        scored_products = []
        for product in response.data:
            scored_products.append({
                "score": 0.99, # Dummy score to satisfy your Flutter UI model mapping
                "product": product
            })

        return {
            "query_status": "success",
            "total_matches": len(scored_products),
            "matches": scored_products
        }
        
    except Exception as e:
        print(f"Visual Search Error: {e}")
        raise HTTPException(status_code=500, detail="Failed to process visual search.")


@router.post("/index-inventory")
def index_existing_products():
    """
    Finds products missing a vector, downloads their image from cloud storage, 
    calculates the CLIP embedding, and saves it to the Supabase pgvector column.
    """
    # 1. Fetch only the products where the new pgvector column is empty
    response = supabase.table("products").select("*").is_("image_embedding", "null").execute()
    products = response.data
    
    indexed_count = 0
    
    for product in products:
        if not product.get("image_url"):
            continue
            
        try:
            # 2. Fetch the image bytes directly from your public URL
            req = urllib.request.Request(
                product["image_url"], 
                headers={'User-Agent': 'Mozilla/5.0'}
            )
            with urllib.request.urlopen(req) as res:
                image_bytes = res.read()
            
            # 3. Convert the raw image into a math vector via CLIP
            vector = generate_image_vector(image_bytes)
            
            # 4. Save the vector directly into the PostgreSQL vector column
            supabase.table("products").update({"image_embedding": vector}).eq("id", product["id"]).execute()
            
            indexed_count += 1
            print(f"Indexed: {product['name']}")
            
        except Exception as e:
            print(f"[INDEXING ERROR] Failed to process product ID {product['id']}: {str(e)}")
            continue
            
    return {"message": f"Successfully generated visual embeddings for {indexed_count} products."}