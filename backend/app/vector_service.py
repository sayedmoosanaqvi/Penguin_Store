"""
Lightweight image embedding service with automatic blur detection,
multi-scale unsharp deconvolution, EXIF orientation correction,
and multi-variant query embedding.

Model:
    Qdrant/resnet50-onnx

Output:
    2048-dimensional L2-normalized image embedding.

Designed for:
    Python 3.11+
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
from typing import Any

import numpy as np
from fastembed import ImageEmbedding
from PIL import Image, ImageFilter, ImageOps

MODEL_NAME = "Qdrant/resnet50-onnx"
EXPECTED_DIMENSION = 2048
CACHE_DIR = os.getenv("FASTEMBED_CACHE_PATH", "/tmp/fastembed_cache")


def _l2_normalize(vec: np.ndarray) -> np.ndarray:
    norm = float(np.linalg.norm(vec))
    if norm > 1e-12:
        return vec / norm
    return vec


def _compute_image_metrics(img: Image.Image) -> dict[str, Any]:
    """
    Compute lightweight spatial sharpness (Laplacian variance),
    contrast (standard deviation), and gradient statistics on a
    normalized 224x224 view of the image.
    """
    resized_rgb = np.asarray(
        img.resize((224, 224), Image.Resampling.BILINEAR),
        dtype=np.float32,
    )
    color_std = float(np.std(resized_rgb))

    gray = (
        0.299 * resized_rgb[:, :, 0]
        + 0.587 * resized_rgb[:, :, 1]
        + 0.114 * resized_rgb[:, :, 2]
    )

    laplacian = (
        -4.0 * gray[1:-1, 1:-1]
        + gray[:-2, 1:-1]
        + gray[2:, 1:-1]
        + gray[1:-1, :-2]
        + gray[1:-1, 2:]
    )
    sharpness_score = float(np.var(laplacian))

    gx = np.abs(gray[:, 1:] - gray[:, :-1])
    gy = np.abs(gray[1:, :] - gray[:-1, :])
    edge_mean = float(0.5 * (np.mean(gx) + np.mean(gy)))

    # Detect solid-color blank images or pure random static noise
    is_solid_blank = color_std < 3.5 or sharpness_score < 0.15
    is_random_noise = sharpness_score > 15000.0 and edge_mean > 65.0

    is_blurry = (not is_solid_blank) and sharpness_score < 320.0
    is_heavily_blurred = (not is_solid_blank) and sharpness_score < 85.0

    return {
        "sharpness_score": round(sharpness_score, 2),
        "color_std": round(color_std, 2),
        "edge_mean": round(edge_mean, 2),
        "is_blurry": bool(is_blurry),
        "is_heavily_blurred": bool(is_heavily_blurred),
        "is_blank_or_noise": bool(is_solid_blank or is_random_noise),
    }


def _build_query_variants(
    img: Image.Image,
    metrics: dict[str, Any],
) -> tuple[list[Image.Image], list[float]]:
    """
    Create a small set of enhanced image views so blurry, low-contrast,
    or background-padded user photos match catalog items accurately.
    """
    variants: list[Image.Image] = [img]
    weights: list[float] = [1.0]

    contrast_img = ImageOps.autocontrast(img, cutoff=1)

    if metrics["is_blurry"]:
        # Variant 1: Moderate UnsharpMask deconvolution + contrast restoration
        deblur_mod = contrast_img.filter(
            ImageFilter.UnsharpMask(
                radius=3.0,
                percent=220,
                threshold=2,
            )
        )
        variants.append(deblur_mod)
        weights.append(0.98)

        # Variant 2: Deep wide-kernel UnsharpMask for heavy defocus/motion blur
        deblur_strong = (
            contrast_img.filter(
                ImageFilter.UnsharpMask(
                    radius=6.0,
                    percent=280,
                    threshold=1,
                )
            ).filter(ImageFilter.SHARPEN)
        )
        variants.append(deblur_strong)
        weights.append(0.96 if metrics["is_heavily_blurred"] else 0.92)

        base_for_crop = (
            deblur_strong
            if metrics["is_heavily_blurred"]
            else deblur_mod
        )
    else:
        base_for_crop = contrast_img

    # Variant 3: Central 80% subject crop (helps when user photo includes table/background)
    w, h = base_for_crop.size
    if w >= 120 and h >= 120:
        crop_box = (
            int(w * 0.10),
            int(h * 0.10),
            int(w * 0.90),
            int(h * 0.90),
        )
        cropped = base_for_crop.crop(crop_box)
        variants.append(cropped)
        weights.append(0.94)

    return variants, weights


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
                threads=2,
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
                raw_image = Image.open(BytesIO(image_bytes))
                raw_image = ImageOps.exif_transpose(raw_image)
                image = raw_image.convert("RGB")

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

            vec_np = _l2_normalize(
                np.asarray(vector, dtype=np.float32)
            )
            vector_list = [float(value) for value in vec_np]

            if len(vector_list) != EXPECTED_DIMENSION:
                raise RuntimeError(
                    f"Image model returned "
                    f"{len(vector_list)} dimensions; "
                    f"expected {EXPECTED_DIMENSION}."
                )

            return vector_list

    def analyze_and_embed_query(
        self,
        image_bytes: bytes,
    ) -> dict[str, Any]:
        """
        Analyze an uploaded user query image, automatically apply blur
        restoration and subject cropping when needed, and return both
        the primary 2048-D embedding and multi-variant embeddings for
        high-accuracy catalog matching.
        """
        if not image_bytes:
            raise ValueError("Image data is empty.")

        model = self._get_model()

        raw_image = None
        rgb_image = None
        variants: list[Image.Image] = []

        try:
            try:
                raw_image = Image.open(BytesIO(image_bytes))
                raw_image = ImageOps.exif_transpose(raw_image)
                rgb_image = raw_image.convert("RGB")
            except Exception as exc:
                raise ValueError(
                    "Invalid or unsupported image file."
                ) from exc

            metrics = _compute_image_metrics(rgb_image)
            variants, weights = _build_query_variants(
                rgb_image,
                metrics,
            )

            with self._inference_lock:
                raw_embeddings = list(
                    model.embed(
                        variants,
                        batch_size=len(variants),
                        parallel=None,
                    )
                )

            if not raw_embeddings:
                raise RuntimeError("No image embeddings were produced.")

            norm_vectors: list[np.ndarray] = []
            for emb in raw_embeddings:
                arr = _l2_normalize(
                    np.asarray(emb, dtype=np.float32)
                )
                if arr.shape[0] != EXPECTED_DIMENSION:
                    raise RuntimeError(
                        f"Unexpected embedding dimension {arr.shape[0]}."
                    )
                norm_vectors.append(arr)

            # Build an L2-normalized ensemble vector combining all variants
            ensemble = np.zeros(EXPECTED_DIMENSION, dtype=np.float32)
            for arr, weight in zip(norm_vectors, weights):
                ensemble += arr * float(weight)
            ensemble = _l2_normalize(ensemble)

            return {
                "primary_vector": [float(x) for x in ensemble],
                "base_vector": [float(x) for x in norm_vectors[0]],
                "variant_vectors": [
                    [float(x) for x in arr]
                    for arr in norm_vectors
                ],
                "variant_weights": weights,
                "sharpness_score": metrics["sharpness_score"],
                "color_std": metrics["color_std"],
                "is_blurry": metrics["is_blurry"],
                "is_heavily_blurred": metrics["is_heavily_blurred"],
                "was_deblurred": bool(metrics["is_blurry"]),
                "is_blank_or_noise": metrics["is_blank_or_noise"],
            }

        except ValueError:
            raise
        except Exception as exc:
            raise RuntimeError(
                "Failed to generate query image embedding."
            ) from exc
        finally:
            for v in variants:
                if v is not rgb_image and v is not raw_image:
                    try:
                        v.close()
                    except Exception:
                        pass
            if rgb_image is not None and rgb_image is not raw_image:
                try:
                    rgb_image.close()
                except Exception:
                    pass
            if raw_image is not None:
                try:
                    raw_image.close()
                except Exception:
                    pass


image_service = ImageVectorService()


def generate_image_vector(image_bytes: bytes) -> list[float]:
    return image_service.generate_image_vector(image_bytes)


def analyze_and_embed_query(image_bytes: bytes) -> dict[str, Any]:
    return image_service.analyze_and_embed_query(image_bytes)
