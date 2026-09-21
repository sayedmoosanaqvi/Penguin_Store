import torch
import torchvision.transforms as transforms
import torchvision.models as models
from PIL import Image
import io

# 1. Load the lightweight MobileNetV3 model optimized for speed
weights = models.MobileNet_V3_Small_Weights.DEFAULT
model = models.mobilenet_v3_small(weights=weights)
model.eval() # Lock the model for inference only

# 2. Define the standard image transformations required by PyTorch vision models
preprocess = transforms.Compose([
    transforms.Resize(256),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(mean=[0.485, 0.456, 0.406], std=[0.229, 0.224, 0.225]),
])

def extract_image_embedding(image_bytes: bytes) -> str:
    """
    Takes raw image bytes, runs it through MobileNetV3, and outputs a 
    1000-dimensional mathematical feature vector as a string for Postgres.
    """
    try:
        # Convert raw bytes to a standard RGB image
        image = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        input_tensor = preprocess(image)
        
        # Create a mini-batch as expected by the model (shape: [1, 3, 224, 224])
        input_batch = input_tensor.unsqueeze(0) 

        # Forward pass through the neural network
        with torch.no_grad():
            output = model(input_batch)
        
        # Flatten the tensor into a simple list of floats
        vector = output.squeeze().tolist()
        
        # Convert to a comma-separated string so it easily saves to your Text column
        return ",".join(map(str, vector))
    
    except Exception as e:
        print(f"[VISION ENGINE ERROR] {str(e)}")
        return ""