"""Comprehensive End-to-End Production Smoke Verification Suite for Penguin Store.
Tests all critical components, routing, configuration, domain resolution, AI services, and ORM.
"""

import sys
import os
import unittest
from pathlib import Path

# Add backend directory to sys.path
backend_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(backend_dir))

class TestPenguinStoreSuite(unittest.TestCase):

    def test_01_configuration_and_domain_whitelist(self):
        """Verify custom domain penguinstore.co and GitHub Pages are in allowed CORS origins."""
        from app.core.config import get_settings
        settings = get_settings()
        origins = settings.allowed_origins
        self.assertIn("https://penguin-store.github.io", origins)
        self.assertIn("https://penguinstore.co", origins)
        self.assertIn("https://www.penguinstore.co", origins)
        self.assertIn("https://sayedmoosanaqvi.github.io", origins)

    def test_02_stripe_return_domain_resolution(self):
        """Verify Stripe redirect resolution supports localhost, github.io, and penguinstore.co."""
        from app.routers.stripe import resolve_frontend_url

        # Localhost development
        self.assertEqual(
            resolve_frontend_url("http://localhost:54321"),
            "http://localhost:54321",
        )
        self.assertEqual(
            resolve_frontend_url("http://127.0.0.1:8080"),
            "http://127.0.0.1:8080",
        )
        # Custom domain penguinstore.co
        self.assertEqual(
            resolve_frontend_url("https://penguinstore.co"),
            "https://penguinstore.co",
        )
        self.assertEqual(
            resolve_frontend_url("https://www.penguinstore.co"),
            "https://www.penguinstore.co",
        )
        # GitHub Pages
        self.assertEqual(
            resolve_frontend_url("https://sayedmoosanaqvi.github.io/Penguin_Store"),
            "https://sayedmoosanaqvi.github.io/Penguin_Store",
        )

    def test_03_fastapi_endpoints_health_and_root(self):
        """Verify root and health endpoints return 200 with online status."""
        from fastapi.testclient import TestClient
        from app.main import app

        client = TestClient(app)
        res_root = client.get("/")
        self.assertEqual(res_root.status_code, 200)
        self.assertEqual(res_root.json().get("status"), "online")

        res_health = client.get("/health")
        self.assertEqual(res_health.status_code, 200)
        self.assertEqual(res_health.json().get("status"), "healthy")

    def test_04_multimodal_inline_price_parser(self):
        """Verify NLP price and 3D intent extraction from user natural language queries."""
        from app.services.multimodal_search_service import _parse_inline_price_constraints

        # Under $100
        emin, emax, has_3d = _parse_inline_price_constraints("sneakers under $100", None, None)
        self.assertIsNone(emin)
        self.assertEqual(emax, 100.0)
        self.assertFalse(has_3d)

        # Between $50 and $150 with 3d
        emin, emax, has_3d = _parse_inline_price_constraints("office chair between $50 and $150 with 3d model", None, None)
        self.assertEqual(emin, 50.0)
        self.assertEqual(emax, 150.0)
        self.assertTrue(has_3d)

        # Over $200
        emin, emax, has_3d = _parse_inline_price_constraints("luxury watch over $200", None, None)
        self.assertEqual(emin, 200.0)
        self.assertIsNone(emax)

    def test_05_review_trust_engine_sentiment_and_entropy(self):
        """Verify Review Trust Shannon entropy and aspect extraction."""
        from app.services.review_trust_service import (
            _shannon_char_entropy,
            _extract_aspect_sentiments,
        )

        # High entropy natural text
        entropy_normal = _shannon_char_entropy("This mechanical keyboard is exceptionally durable and high quality.")
        self.assertGreater(entropy_normal, 3.5)

        # Low entropy bot-like repetitive spam
        entropy_spam = _shannon_char_entropy("aaaaaaa aaaaaa aaaaaa")
        self.assertLess(entropy_spam, 2.0)

        # Aspect extraction
        aspects = _extract_aspect_sentiments("The material build quality is premium, but delivery was late.", 4)
        self.assertEqual(aspects.get("Quality"), "positive")
        self.assertEqual(aspects.get("Delivery/Experience"), "negative")

    def test_06_planner_safe_parsing_and_normalization(self):
        """Verify AI multi-agent orchestrator parser handles clean and malformed JSON."""
        from app.agent.multi_agent_orchestrator import (
            _normalize_shopping_plan,
            _parse_json_object,
        )

        valid_raw = '```json\n{"action": "search", "category": "laptops", "max_price": 1200}\n```'
        parsed = _parse_json_object(valid_raw)
        self.assertEqual(parsed.get("action"), "search")
        self.assertEqual(parsed.get("max_price"), 1200)

        plan = _normalize_shopping_plan(parsed)
        self.assertEqual(plan["action"], "search")
        self.assertEqual(plan["category"], "laptops")
        self.assertEqual(plan["max_price"], 1200.0)

    def test_07_all_orm_models_present(self):
        """Verify all 16 database ORM models are registered."""
        import app.models as models
        expected_models = [
            "User", "Product", "Order", "OrderItem", "Notification",
            "Product3DAsset", "PremiumSubscription", "Review",
            "WishlistItem", "RecentlyViewedItem", "UserAddress",
            "CartItemModel", "CtrlXAuditLog", "ProductReviewInsight",
            "AIMetricsLog", "RFQRequest",
        ]
        for name in expected_models:
            self.assertTrue(hasattr(models, name), f"Model {name} missing from models.py")

    def test_08_hybrid_search_and_gibberish_empty_state(self):
        """Verify GET /api/v1/products/search returns relevant matches and 0 items on gibberish."""
        from fastapi.testclient import TestClient
        from app.main import app

        client = TestClient(app)
        res_search = client.get("/api/v1/products/search", params={"q": "shirt"})
        self.assertEqual(res_search.status_code, 200)
        self.assertIsInstance(res_search.json(), list)

        res_gibberish = client.get("/api/v1/products/search", params={"q": "zzzzqxnonexistent998877"})
        self.assertEqual(res_gibberish.status_code, 200)
        self.assertEqual(res_gibberish.json(), [])

    def test_09_active_product_filtering_and_tombstone_protection(self):
        """Verify soft-deleted / tombstoned products are excluded and Product #144 is protected."""
        from app.core.supabase_rest import (
            is_product_active_row,
            mark_product_deleted,
            unmark_product_deleted,
        )

        self.assertTrue(is_product_active_row({"id": 144, "name": "Reference 3D", "stock": 10, "is_active": True}))
        self.assertFalse(is_product_active_row({"id": 999991, "name": "Hidden", "stock": 10, "is_active": False}))
        self.assertFalse(is_product_active_row({"id": 999992, "name": "[Archived] Old Item", "stock": 0}))
        self.assertFalse(is_product_active_row({"id": 999993, "name": "Tombstoned", "stock": -1}))

        mark_product_deleted(999994)
        try:
            self.assertFalse(is_product_active_row({"id": 999994, "name": "Active Row", "stock": 10}))
        finally:
            unmark_product_deleted(999994)


if __name__ == "__main__":
    unittest.main(verbosity=2)
