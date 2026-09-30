from fastembed import ImageEmbedding
from PIL import Image
import io

# Load the lightweight ONNX CLIP model into memory (will not crash Render)
model = ImageEmbedding(model_name="Qdrant/clip-ViT-B-32-vision")

def generate_image_vector(image_bytes: bytes) -> list[float]:
    # 1. Open the raw image bytes
    image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    
    # 2. FastEmbed automatically handles the extraction locally
    embeddings = list(model.embed([image]))
    
    # 3. Format the output into a standard Python float list for Supabase pgvector
    return [float(x) for x in embeddings[0]]