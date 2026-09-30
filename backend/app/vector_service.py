import os
import requests

def generate_image_vector(image_bytes: bytes) -> list[float]:
    """
    Sends raw image bytes directly to the Hugging Face API using standard requests.
    Render's cloud servers will natively resolve this without regional DNS blocks.
    """
    hf_token = os.getenv("HUGGINGFACE_TOKEN")
    
    # 1. Set the correct headers for raw byte processing
    headers = {"Content-Type": "application/octet-stream"}
    if hf_token:
        headers["Authorization"] = f"Bearer {hf_token}"
        
    # 2. Use the modern active router endpoint
    api_url = "https://router.huggingface.co/hf-inference/models/openai/clip-vit-base-patch32"
    
    try:
        response = requests.post(api_url, headers=headers, data=image_bytes)
        response.raise_for_status() 
        
        vector = response.json()
        
        # 3. Format the output into a standard Python float list for Supabase pgvector
        if isinstance(vector, list) and len(vector) > 0 and isinstance(vector[0], list):
            return [float(x) for x in vector[0]]
            
        return [float(x) for x in vector]
        
    except Exception as e:
        raise Exception(f"Hugging Face API Error: {str(e)}")