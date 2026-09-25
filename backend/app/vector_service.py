import io
from PIL import Image
from sentence_transformers import SentenceTransformer

# Initialize the CLIP model globally so it loads into memory only once upon server startup.
# The ViT-B-32 model generates exact 512-dimensional vectors.
print("Loading CLIP Vision Model...")
vision_model = SentenceTransformer('clip-ViT-B-32')
print("CLIP Model Loaded Successfully.")

def generate_image_vector(image_bytes: bytes) -> list[float]:
    """
    Takes raw image bytes, processes them through the CLIP AI model, 
    and returns a 512-dimensional mathematical array.
    """
    # Open the image using PIL and ensure it is in standard RGB format
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    
    # Generate the mathematical embedding
    vector = vision_model.encode(image)
    
    # Convert the numpy array to a standard Python list for Supabase
    return vector.tolist()