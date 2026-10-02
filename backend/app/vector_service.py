"""
Lightweight CLIP image embedding service.

Model:
    Qdrant/clip-ViT-B-32-vision

Output:
    512-dimensional CLIP image embedding.

Designed for:
    Python 3.11
    FastAPI
    Render low-memory environments

No torch.
No torchvision.
No transformers.
"""

from __future__ import annotations

import os
from io import BytesIO
from threading import Lock

from fastembed import ImageEmbedding
from PIL import Image


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MODEL_NAME = "Qdrant/clip-ViT-B-32-vision"
EXPECTED_DIMENSION = 512

CACHE_DIR = os.getenv(
    "FASTEMBED_CACHE_PATH",
    "/tmp/fastembed_cache",
)


# ---------------------------------------------------------------------------
# CLIP service
# ---------------------------------------------------------------------------

class ClipVectorService:
    """
    Process-wide CLIP embedding service.

    Memory-conscious design:
        - one model instance
        - lazy model initialization
        - one ONNX thread
        - batch size of one
        - inference serialized to avoid memory spikes
    """

    def __init__(self) -> None:
        self._model: ImageEmbedding | None = None

        # Protects model creation only.
        self._model_lock = Lock()

        # Prevents multiple image inference operations from happening
        # simultaneously on the small Render instance.
        self._inference_lock = Lock()

    # ---------------------------------------------------------------------
    # Model initialization
    # ---------------------------------------------------------------------

    def _get_model(self) -> ImageEmbedding:
        """
        Lazily initialize the FastEmbed CLIP model.

        The model is NOT loaded when this module is imported.
        """

        if self._model is not None:
            return self._model

        with self._model_lock:

            # Double-check after acquiring the lock.
            if self._model is not None:
                return self._model

            os.makedirs(CACHE_DIR, exist_ok=True)

            model = ImageEmbedding(
                model_name=MODEL_NAME,
                cache_dir=CACHE_DIR,
                threads=1,
                providers=["CPUExecutionProvider"],
                lazy_load=False,
            )

            # Make sure this is actually the 512-D model we expect.
            if model.embedding_size != EXPECTED_DIMENSION:
                raise RuntimeError(
                    f"Unexpected CLIP embedding dimension: "
                    f"{model.embedding_size}. "
                    f"Expected {EXPECTED_DIMENSION}."
                )

            self._model = model

            return self._model

    # ---------------------------------------------------------------------
    # Image embedding
    # ---------------------------------------------------------------------

    def generate_image_vector(
        self,
        image_bytes: bytes,
    ) -> list[float]:
        """
        Convert raw image bytes into a 512-dimensional CLIP vector.
        """

        if not image_bytes:
            raise ValueError("Image data is empty.")

        # Load the model first.
        model = self._get_model()

        # Serialize inference on the 512 MB instance.
        with self._inference_lock:

            image = None

            try:
                # Decode uploaded image in memory.
                image = Image.open(
                    BytesIO(image_bytes)
                ).convert("RGB")

                # Keep inference as small as possible.
                embeddings = model.embed(
                    [image],
                    batch_size=1,
                    parallel=None,
                )

                vector = next(iter(embeddings))

            except Exception as exc:
                raise RuntimeError(
                    "Failed to generate CLIP image embedding."
                ) from exc

            finally:
                if image is not None:
                    image.close()

            # Convert NumPy values to normal Python floats.
            vector_list = [
                float(value)
                for value in vector
            ]

            # Final safety check.
            if len(vector_list) != EXPECTED_DIMENSION:
                raise RuntimeError(
                    f"CLIP returned {len(vector_list)} dimensions; "
                    f"expected {EXPECTED_DIMENSION}."
                )

            return vector_list


# ---------------------------------------------------------------------------
# Singleton service
# ---------------------------------------------------------------------------

clip_service = ClipVectorService()


# ---------------------------------------------------------------------------
# Existing public function
# ---------------------------------------------------------------------------

def generate_image_vector(
    image_bytes: bytes,
) -> list[float]:
    """
    Backwards-compatible helper.

    Existing routes can continue using:

        generate_image_vector(image_bytes)
    """

    return clip_service.generate_image_vector(image_bytes)