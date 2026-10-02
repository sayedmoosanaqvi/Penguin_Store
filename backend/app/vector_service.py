"""
Lightweight image embedding service.

Model:
    Qdrant/resnet50-onnx

Output:
    2048-dimensional image embedding.

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

MODEL_NAME = "Qdrant/resnet50-onnx"
EXPECTED_DIMENSION = 2048
CACHE_DIR = os.getenv("FASTEMBED_CACHE_PATH", "/tmp/fastembed_cache")


class ImageVectorService:
    def __init__(self) -> None:
        self._model: ImageEmbedding | None = None
        self._model_lock = Lock()
        self._inference_lock = Lock()

    def _get_model(self) -> ImageEmbedding:
        if self._model is not None:
            return self._model

        with self._model_lock:
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

            if model.embedding_size != EXPECTED_DIMENSION:
                raise RuntimeError(
                    f"Unexpected image embedding dimension: "
                    f"{model.embedding_size}. "
                    f"Expected {EXPECTED_DIMENSION}."
                )

            self._model = model
            return self._model

    def generate_image_vector(self, image_bytes: bytes) -> list[float]:
        if not image_bytes:
            raise ValueError("Image data is empty.")

        model = self._get_model()

        with self._inference_lock:
            image = None

            try:
                image = Image.open(
                    BytesIO(image_bytes)
                ).convert("RGB")

                embeddings = model.embed(
                    [image],
                    batch_size=1,
                    parallel=None,
                )

                vector = next(iter(embeddings))

            except Exception as exc:
                raise RuntimeError(
                    "Failed to generate image embedding."
                ) from exc

            finally:
                if image is not None:
                    image.close()

            vector_list = [float(value) for value in vector]

            if len(vector_list) != EXPECTED_DIMENSION:
                raise RuntimeError(
                    f"Image model returned "
                    f"{len(vector_list)} dimensions; "
                    f"expected {EXPECTED_DIMENSION}."
                )

            return vector_list


image_service = ImageVectorService()


def generate_image_vector(image_bytes: bytes) -> list[float]:
    return image_service.generate_image_vector(image_bytes)