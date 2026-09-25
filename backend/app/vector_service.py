import os
from huggingface_hub import InferenceClient

# Initialize the lightweight HTTP client
# Optional: Add HUGGINGFACE_TOKEN to your Render environment variables to bypass public rate limits
hf_token = os.getenv("HUGGINGFACE_TOKEN")
client = InferenceClient(token=hf_token)

def generate_image_vector(image_bytes: bytes) -> list[float]:
    """
    Sends raw image bytes to the Hugging Face Router via the official InferenceClient.
    Automatically handles the new API endpoints without requiring local PyTorch memory.
    """
    try:
        # Use the feature_extraction task to get the CLIP vector
        vector = client.feature_extraction(
            data=image_bytes,
            model="openai/clip-vit-base-patch32"
        )
        
        # Format the output into a standard Python float list for Supabase pgvector
        if isinstance(vector, list) and len(vector) > 0 and isinstance(vector[0], list):
            return [float(x) for x in vector[0]]
            
        return [float(x) for x in vector]
        
    except Exception as e:
        raise Exception(f"Hugging Face Inference Error: {str(e)}")