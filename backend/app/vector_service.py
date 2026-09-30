import os
import requests

def generate_image_vector(image_bytes: bytes) -> list[float]:
    # Swapped to a model that explicitly returns feature vectors instead of image classification
    api_url = "https://router.huggingface.co/hf-inference/models/sentence-transformers/clip-ViT-B-32"
    
    headers = {
        "Authorization": f"Bearer {os.getenv('HUGGINGFACE_TOKEN')}",
        "Content-Type": "application/octet-stream"
    }
    
    response = requests.post(api_url, headers=headers, data=image_bytes)
    
    if response.status_code != 200:
        raise Exception(f"Hugging Face API Error: {response.status_code} - {response.text}")
        
    vector = response.json()
    
    # Format the output into a standard Python float list for pgvector
    if isinstance(vector, list) and len(vector) > 0 and isinstance(vector[0], list):
        return [float(x) for x in vector[0]]
        
    return [float(x) for x in vector]