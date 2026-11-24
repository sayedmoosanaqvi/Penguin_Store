"""Automated Production Hardening & Release Sign-Off Test Suite (Phases 1-6).

Covers:
  1. Health & Readiness probes (/health, /ready) + HTTP Security Headers & HSTS
  2. Strict RBAC (401 Unauthenticated, 403 Customer on Admin routes, #144 Protection)
  3. Anti-IDOR Ownership Enforcement (/api/v1/rfq/my, /api/orders/history, /api/orders/detail)
  4. Authoritative Server-Side Pricing, Variant/Add-on Deltas, B2B MOQ Tiers & Promo Integrity
  5. Binary Magic-Byte Upload Security (PNG/JPEG/WebP vs Polyglot/Script + GLB 2.0 25MB guard)
  6. Memory-Bounded Sliding-Window Rate Limiting (429 Too Many Requests + Retry-After header)
  7. SpeechTextCleaner / sanitize_spoken_text Dual-Channel Voice Sanitization
"""

from __future__ import annotations

import os
import struct
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.agent.voice_formatter import SpeechTextCleaner, sanitize_spoken_text  # noqa: E402
from app.core.security import create_access_token, get_current_user, get_optional_current_user  # noqa: E402
from app.core.upload_security import validate_glb_upload, validate_image_upload  # noqa: E402
from app.main import app  # noqa: E402
from app.middleware.security import reset_rate_limiter_for_tests  # noqa: E402
from app.routers.orders import (  # noqa: E402
    CartItem,
    calculate_server_order_pricing,
    compute_authoritative_unit_price,
)


@pytest.fixture(autouse=True)
def _clean_rate_limiter_and_overrides():
    reset_rate_limiter_for_tests()
    app.dependency_overrides.clear()
    yield
    app.dependency_overrides.clear()
    reset_rate_limiter_for_tests()


@pytest.fixture()
def client() -> TestClient:
    return TestClient(app)


def _fake_user(user_id: int, email: str, role: str = "customer"):
    return SimpleNamespace(
        id=user_id,
        email=email,
        is_admin=(role == "admin"),
        role=role,
        is_active=True,
        full_name="Test User",
    )


# ---------------------------------------------------------------------------
# 1. Availability & Security Headers (/health, /ready, HSTS, Permissions-Policy)
# ---------------------------------------------------------------------------

def test_health_and_readiness_with_security_headers(client: TestClient):
    h_res = client.get("/health", headers={"X-Forwarded-Proto": "https"})
    assert h_res.status_code == 200
    assert h_res.json()["status"] == "healthy"
    assert h_res.headers.get("X-Content-Type-Options") == "nosniff"
    assert h_res.headers.get("X-Frame-Options") == "DENY"
    assert h_res.headers.get("Referrer-Policy") == "strict-origin-when-cross-origin"
    assert "microphone=(self)" in (h_res.headers.get("Permissions-Policy") or "")
    assert "max-age=31536000" in (h_res.headers.get("Strict-Transport-Security") or "")

    r_res = client.get("/ready")
    assert r_res.status_code == 200
    body = r_res.json()
    assert body["status"] == "ready"
    assert isinstance(body.get("catalog_cached_count"), int)


# ---------------------------------------------------------------------------
# 2. Confidentiality: Strict RBAC (401 / 403) & Product #144 Protection
# ---------------------------------------------------------------------------

def test_rbac_unauthenticated_and_customer_blocked_from_admin_mutations(client: TestClient):
    # Unauthenticated -> 401
    assert client.post("/products/", json={"name": "X", "price": 10, "category": "Tech"}).status_code == 401
    assert client.delete("/products/999999").status_code == 401
    assert client.get("/api/v1/admin/rfq").status_code == 401
    assert client.get("/api/orders/admin/all").status_code == 401

    # Authenticated non-admin customer -> 403 Forbidden
    customer = _fake_user(101, "customer@penguinstore.co", role="customer")
    app.dependency_overrides[get_current_user] = lambda: customer

    assert client.post(
        "/products/",
        json={"name": "Unauthorized Item", "price": 19.99, "category": "Tech"},
    ).status_code == 403
    assert client.delete("/products/999999").status_code == 403
    assert client.get("/api/v1/admin/rfq").status_code == 403
    assert client.get("/api/orders/admin/all").status_code == 403


def test_product_144_is_protected_even_from_admin_deletion(client: TestClient):
    admin = _fake_user(1, "admin@penguinstore.co", role="admin")
    app.dependency_overrides[get_current_user] = lambda: admin

    res = client.delete("/api/v1/products/144")
    assert res.status_code == 403
    assert "144" in res.json().get("detail", "")


# ---------------------------------------------------------------------------
# 3. Confidentiality: Anti-IDOR Ownership Enforcement
# ---------------------------------------------------------------------------

def test_anti_idor_on_rfq_and_order_history(client: TestClient):
    # Unauthenticated RFQ /my query -> 401 (no email query parameter leak)
    unauth = client.get("/api/v1/rfq/my?email=ceo@enterprise.com")
    assert unauth.status_code == 401

    # Logged in as Alice trying to read Bob's RFQs & Bob's Order History -> 403 Forbidden
    alice = _fake_user(202, "alice@penguinstore.co", role="customer")
    app.dependency_overrides[get_current_user] = lambda: alice

    rfq_idor = client.get("/api/v1/rfq/my?email=bob@penguinstore.co")
    assert rfq_idor.status_code == 403

    orders_idor = client.get("/api/orders/history/bob@penguinstore.co")
    assert orders_idor.status_code == 403

    # Alice querying her own RFQs succeeds -> 200 OK
    own_rfq = client.get("/api/v1/rfq/my")
    assert own_rfq.status_code == 200


def test_anti_idor_on_single_order_detail_and_tampered_price_rejection(client: TestClient):
    # Pick a live active product from catalog
    prods_res = client.get("/api/v1/products/?limit=5")
    assert prods_res.status_code == 200
    products = prods_res.json()
    assert len(products) >= 1
    target_prod = next((p for p in products if int(p.get("stock") or 50) >= 2), products[0])
    pid = int(target_prod["id"])
    real_price = float(target_prod["price"])

    # Attacker attempts checkout with tampered $0.01 unit_price, $9999 discount, $0 tax, fake promo
    checkout_res = client.post(
        "/api/orders/checkout",
        json={
            "customer_name": "Alice Buyer",
            "customer_email": "alice@penguinstore.co",
            "shipping_address": "42 Glacier Ave",
            "city": "Lahore",
            "state_province": "Punjab",
            "country": "Pakistan",
            "postal_code": "54000",
            "promo_code": "FAKE_100_PERCENT_OFF",
            "discount_amount": 9999.0,
            "tax_amount": 0.0,
            "payment_method": "STRIPE",  # pending payment so live stock isn't mutated during test
            "items": [
                {
                    "product_id": pid,
                    "quantity": 1,
                    "unit_price": 0.01,
                    "selected_variant": "Standard Edition",
                    "selected_addons": [],
                }
            ],
        },
    )
    assert checkout_res.status_code == 200
    order_out = checkout_res.json()
    order_id = order_out["order_id"]
    receipt_token = order_out["receipt_token"]

    # Verify server ignored tampered $0.01 price & $9999 discount!
    expected_subtotal = round(real_price, 2)
    expected_tax = round(expected_subtotal * 0.05, 2)
    expected_total = round(expected_subtotal + expected_tax, 2)
    assert order_out["subtotal_amount"] == expected_subtotal
    assert order_out["discount_amount"] == 0.0
    assert order_out["tax_amount"] == expected_tax
    assert order_out["total_charged"] == expected_total

    # 1) Unauthenticated GET /api/orders/detail/{id} without receipt_token -> 401
    assert client.get(f"/api/orders/detail/{order_id}").status_code == 401

    # 2) Forged receipt_token -> 401
    assert (
        client.get(f"/api/orders/detail/{order_id}?receipt_token=forged_token_123").status_code
        == 401
    )

    # 3) Authenticated as Bob (different customer) without receipt_token -> 403 Forbidden
    bob = _fake_user(303, "bob@penguinstore.co", role="customer")
    app.dependency_overrides[get_optional_current_user] = lambda: bob
    assert client.get(f"/api/orders/detail/{order_id}").status_code == 403

    # 4) Valid HMAC receipt_token -> 200 OK
    app.dependency_overrides.pop(get_optional_current_user, None)
    ok_token_res = client.get(
        f"/api/orders/detail/{order_id}",
        params={"receipt_token": receipt_token},
    )
    assert ok_token_res.status_code == 200
    assert ok_token_res.json()["order"]["order_id"] == order_id

    # 5) Authenticated as Alice (owner) -> 200 OK
    alice = _fake_user(202, "alice@penguinstore.co", role="customer")
    app.dependency_overrides[get_optional_current_user] = lambda: alice
    ok_owner_res = client.get(f"/api/orders/detail/{order_id}")
    assert ok_owner_res.status_code == 200


# ---------------------------------------------------------------------------
# 4. Integrity: B2B MOQ Tier Discounts, Add-ons & Promo Calculation Unit Tests
# ---------------------------------------------------------------------------

def test_server_side_b2b_moq_addons_and_promo_math():
    fake_catalog = {
        10: {
            "id": 10,
            "name": "Arctic Studio Headphones",
            "price": 100.0,
            "category": "Electronics",
            "stock": 200,
            "is_active": True,
        }
    }

    # Retail 1 unit ($100)
    assert compute_authoritative_unit_price(fake_catalog[10], quantity=1) == 100.0

    # Corporate Wholesale MOQ 10 units (12% off (100 + 24 Pro Edition)) + Gift Wrap ($9.99)
    # = (124 * 0.88) + 9.99 = 109.12 + 9.99 = 119.11
    unit_b2b_10 = compute_authoritative_unit_price(
        fake_catalog[10],
        quantity=10,
        selected_variant="Pro Edition",
        selected_addons=["Gift Wrapping (+$9.99)"],
    )
    assert unit_b2b_10 == 119.11

    # Enterprise Distributor MOQ 50 units (22% off $100) = $78.00
    assert compute_authoritative_unit_price(fake_catalog[10], quantity=50) == 78.0

    # Full order pricing with PENGUIN10 (10% off) + 5% tax
    pricing = calculate_server_order_pricing(
        items=[
            CartItem(
                product_id=10,
                quantity=2,
                unit_price=0.50,  # tampered client price ignored
                selected_variant="Standard Edition",
                selected_addons=[],
            )
        ],
        promo_code="PENGUIN10",
        product_lookup=lambda pid: fake_catalog.get(pid),
    )
    assert pricing["subtotal"] == 200.0
    assert pricing["discount"] == 20.0
    assert pricing["tax"] == 9.0  # 5% of $180
    assert pricing["total"] == 189.0


# ---------------------------------------------------------------------------
# 5. Integrity: Magic-Byte Binary Upload Security
# ---------------------------------------------------------------------------

def test_magic_byte_validation_for_images_and_glb():
    from fastapi import HTTPException

    # Valid minimal PNG header passes
    valid_png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
    ext, mime = validate_image_upload(valid_png, "product.png")
    assert ext == ".png"
    assert mime == "image/png"

    # Script disguised with .png extension -> rejected (415)
    with pytest.raises(HTTPException) as exc_img:
        validate_image_upload(b"<script>alert('xss')</script>", "evil.png")
    assert exc_img.value.status_code == 415

    # Valid minimal GLB 2.0 container passes
    valid_glb = struct.pack("<4sII", b"glTF", 2, 20) + b"\x00" * 8
    validate_glb_upload(valid_glb, "penguin_twin.glb")

    # Non-GLB binary disguised as .glb -> rejected (422)
    with pytest.raises(HTTPException) as exc_glb:
        validate_glb_upload(b"NOT_A_GLB_HEADER_123456", "fake.glb")
    assert exc_glb.value.status_code == 422

    # Oversized GLB (> 25 MB) -> rejected (413)
    with pytest.raises(HTTPException) as exc_big:
        validate_glb_upload(valid_glb, "huge.glb", max_bytes=10)
    assert exc_big.value.status_code == 413


# ---------------------------------------------------------------------------
# 6. Availability: Sliding-Window Rate Limiter (429 + Retry-After)
# ---------------------------------------------------------------------------

def test_sliding_window_rate_limiter_returns_429_and_retry_after(client: TestClient):
    headers = {"X-Forwarded-For": "203.0.113.77"}
    last_res = None
    # Auth limit is 15 requests / 60s
    for _ in range(16):
        last_res = client.post(
            "/login",
            data={"username": "nobody@penguinstore.co", "password": "wrongpassword123"},
            headers=headers,
        )
    assert last_res is not None
    assert last_res.status_code == 429
    retry_after = last_res.headers.get("Retry-After")
    assert retry_after is not None and int(retry_after) >= 1
    assert last_res.json().get("retry_after_seconds", 0) >= 1


# ---------------------------------------------------------------------------
# 7. Accessibility & Voice UX: SpeechTextCleaner Sanitization
# ---------------------------------------------------------------------------

def test_speech_text_cleaner_strips_markdown_tables_and_symbols():
    raw_llm_output = """
    ### Top Picks Comparison
    ---
    | Product | Price | Trust |
    | --- | --- | --- |
    | Arctic Pro Headset | $249.50 | 98% |

    **Winner:** Order #5088 includes **Arctic Pro Headset** at $249.50 with 98% verified reviews!
    See details at https://penguinstore.co/#/product/144 ✅
    """
    cleaned = SpeechTextCleaner.clean(raw_llm_output)
    assert "---" not in cleaned
    assert "|" not in cleaned
    assert "*" not in cleaned
    assert "#" not in cleaned
    assert "https://" not in cleaned
    assert "order number 5088" in cleaned.lower()
    assert "249 dollars and 50 cents" in cleaned.lower()
    assert "98 percent" in cleaned.lower()
    assert sanitize_spoken_text(raw_llm_output) == cleaned
