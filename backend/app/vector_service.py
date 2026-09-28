import os
import json
from huggingface_hub import InferenceClient

hf_token = os.getenv("HUGGINGFACE_TOKEN")
client = InferenceClient(token=hf_token)

def generate_image_vector(image_bytes: bytes) -> list[float]:
    """
    Sends raw image bytes directly to the Hugging Face Router via HTTP post.
    """
    try:
        # Send raw bytes using the base post method instead of the restricted helper
        response = client.post(
            data=image_bytes,
            model="openai/clip-vit-base-patch32"
        )
        
        # Parse the byte string response into a Python dictionary/list
        vector = json.loads(response)
        
        # Format the output into a standard Python float list for Supabase pgvector
        if isinstance(vector, list) and len(vector) > 0 and isinstance(vector[0], list):
            return [float(x) for x in vector[0]]
            
        return [float(x) for x in vector]
        
    except Exception as e:
        raise Exception(f"Hugging Face Inference Error: {str(e)}")