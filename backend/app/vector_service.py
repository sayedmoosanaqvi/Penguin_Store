import os
import requests

def generate_image_vector(image_bytes: bytes) -> list[float]:
    """
    Sends raw image bytes directly to the Hugging Face API using standard requests.
    Render's cloud servers will natively resolve this without regional DNS blocks.
    """
    hf_token = os.getenv("HUGGINGFACE_TOKEN")
    headers = {"Authorization": f"Bearer {hf_token}"} if hf_token else {}
    api_url = "https://api-inference.huggingface.co/models/openai/clip-vit-base-patch32"
    
    try:
        response = requests.post(api_url, headers=headers, data=image_bytes)
        response.raise_for_status() 
        
        vector = response.json()
        
        # Format the output into a standard Python float list for Supabase pgvector
        if isinstance(vector, list) and len(vector) > 0 and isinstance(vector[0], list):
            return [float(x) for x in vector[0]]
            
        return [float(x) for x in vector]
        
    except Exception as e:
        raise Exception(f"Hugging Face API Error: {str(e)}")