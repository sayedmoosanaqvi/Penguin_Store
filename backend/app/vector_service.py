import os
import requests

# Public Hugging Face inference endpoint for the standard CLIP model
API_URL = "https://api-inference.huggingface.co/models/openai/clip-vit-base-patch32"

def generate_image_vector(image_bytes: bytes) -> list[float]:
    """
    Sends raw image bytes to the inference endpoint and retrieves
    the 512-dimensional CLIP embedding without requiring local PyTorch memory.
    """
    headers = {"User-Agent": "FastAPI-PenguinStore"}
    
    # Optional: If you add HUGGINGFACE_TOKEN to your .env, it prevents public rate limiting
    hf_token = os.getenv("HUGGINGFACE_TOKEN")
    if hf_token:
        headers["Authorization"] = f"Bearer {hf_token}"

    response = requests.post(
        API_URL,
        headers=headers,
        data=image_bytes,
        timeout=15
    )

    if response.status_code != 200:
        raise Exception(f"Vision API error ({response.status_code}): {response.text}")

    vector = response.json()
    
    # Handle nested output format if returned as a 2D array [[...]]
    if isinstance(vector, list) and len(vector) > 0 and isinstance(vector[0], list):
        return vector[0]
        
    return vector