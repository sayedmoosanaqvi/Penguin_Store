"""Pre-Launch QA Automation & High-Concurrency Stress Suite (Phases 1–6).

Covers:
  1. 100 concurrent async catalog & hybrid search requests (0% errors + p50/p95 report + Cache-Control + #144 intact)
  2. Single-flight `asyncio.Lock` cache-stampede coalescing (100 concurrent callers -> 1 DB load) + BoundedLRUDict cap
  3. 50 concurrent cart additions (atomic upsert, zero duplicate rows, strict live stock-cap enforcement)
  4. 25-buyer race-condition checkout for 3 remaining units (3 succeed, 22 get 400, stock == 0, never < 0)
     + multi-item rollback compensation + `Idempotency-Key` replay safety
  5. Flagship Review System integrity (0-review honest empty insights, 1–2 review Early Feedback tier,
     3+ review grounded aspects, paid vs unpaid Verified Purchase check, CRUD + 409 duplicate + 403 ownership + Helpful toggle)
  6. Voice Search accuracy & post-ASR repair (short/silent clip handling, Whisper hallucination filter,
     spoken price normalization 'under two fifty' -> $250, homophone/fuzzy catalog repair 'ear pods' -> 'AirPods')
  7. Visual Search preprocessing & calibrated tiers (EXIF transpose, RGBA->white composite, tiny image guard,
     256->224 standard crop, Strong/Similar/Closest Alternative tiers, RRF anti-inflation verification)
"""

from __future__ import annotations

import asyncio
import io
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app.api.v1.endpoints import commerce as commerce_ep  # noqa: E402
from app.core import supabase_rest  # noqa: E402
from app.core.concurrency import BoundedLRUDict, SingleFlightAsyncCache, global_single_flight  # noqa: E402
from app.core.database import Base, get_db  # noqa: E402
from app.core.security import get_current_user, get_optional_current_user  # noqa: E402
from app.main import app  # noqa: E402
from app.middleware.security import reset_rate_limiter_for_tests  # noqa: E402
from app.models import Product, User  # noqa: E402
from app.routers import orders as orders_router  # noqa: E402
from app.routers.visual_search import classify_visual_confidence  # noqa: E402
from app.routers.voice_ai import (  # noqa: E402
    is_whisper_hallucination_or_silence,
    normalize_spoken_numbers,
    repair_voice_query,
)
from app.services import multimodal_search_service as mm_service  # noqa: E402
from app.services.review_trust_service import get_or_generate_product_review_insights  # noqa: E402
from app.vector_service import prepare_clean_rgb_image, standardize_resnet_crop  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_overrides_and_limiter():
    reset_rate_limiter_for_tests()
    app.dependency_overrides.clear()
    yield
    app.dependency_overrides.clear()
    reset_rate_limiter_for_tests()


def _fake_user(user_id: int, email: str, role: str = "customer"):
    return SimpleNamespace(
        id=user_id,
        email=email,
        is_admin=(role == "admin"),
        role=role,
        is_active=True,
        full_name="QA Shopper",
    )


# ---------------------------------------------------------------------------
# 1. 100 Concurrent Async Catalog & Search Stress Test (p50 / p95 Report)
# ---------------------------------------------------------------------------

def test_01_100_concurrent_catalog_and_search_requests_with_p50_p95():
    endpoints = [
        "/api/v1/products/?limit=24",
        "/api/v1/products/search?q=headphones%20under%20$350",
        "/api/premium-3d/catalog",
        "/api/v1/products/144",
    ]

    async def _run_100_shoppers() -> tuple[list[int], list[float], dict[str, str], dict[str, Any]]:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
            # Warm cache once so we measure steady-state + concurrent read serving
            warm = await ac.get("/api/v1/products/144", headers={"X-Forwarded-For": "10.88.0.1"})
            assert warm.status_code == 200
            prod_144 = warm.json()

            async def _single_req(idx: int) -> tuple[int, float, dict[str, str]]:
                url = endpoints[idx % len(endpoints)]
                ip = f"10.88.{idx // 200}.{(idx % 200) + 2}"
                t0 = time.perf_counter()
                resp = await ac.get(url, headers={"X-Forwarded-For": ip})
                dt_ms = (time.perf_counter() - t0) * 1000.0
                return resp.status_code, dt_ms, dict(resp.headers)

            results = await asyncio.gather(*[_single_req(i) for i in range(100)])
            statuses = [r[0] for r in results]
            latencies = [r[1] for r in results]
            first_headers = results[0][2]
            return statuses, latencies, first_headers, prod_144

    statuses, latencies, headers_sample, prod_144 = asyncio.run(_run_100_shoppers())

    assert len(statuses) == 100
    assert all(code == 200 for code in statuses), f"Expected 100x HTTP 200, got: {set(statuses)}"
    assert int(prod_144["id"]) == 144, "Product #144 must remain intact and active"

    cc = headers_sample.get("cache-control", "")
    assert "max-age=15" in cc and "stale-while-revalidate=45" in cc

    sorted_lat = sorted(latencies)
    p50_ms = sorted_lat[int(0.50 * (len(sorted_lat) - 1))]
    p95_ms = sorted_lat[int(0.95 * (len(sorted_lat) - 1))]
    print(f"\n[STRESS] 100 Concurrent Requests -> 0% errors | p50={p50_ms:.2f}ms | p95={p95_ms:.2f}ms")
    assert p95_ms < 5000.0


# ---------------------------------------------------------------------------
# 2. Single-Flight Stampede Protection & Bounded LRU Memory Safety
# ---------------------------------------------------------------------------

def test_02_single_flight_stampede_coalescing_and_bounded_lru():
    cache = SingleFlightAsyncCache(max_entries=32, default_ttl=30.0)
    loader_calls = 0

    async def _slow_db_query() -> dict[str, Any]:
        nonlocal loader_calls
        loader_calls += 1
        await asyncio.sleep(0.04)
        return {"items": [1, 2, 3], "seq": loader_calls}

    async def _hammer_cold_key():
        return await asyncio.gather(
            *[cache.get_or_load("catalog:cold", _slow_db_query) for _ in range(100)]
        )

    outputs = asyncio.run(_hammer_cold_key())
    assert loader_calls == 1, f"SingleFlight must coalesce 100 concurrent callers into 1 load, got {loader_calls}"
    assert all(o["seq"] == 1 for o in outputs)

    lru: BoundedLRUDict[int] = BoundedLRUDict(max_size=64)
    for i in range(500):
        lru.set(f"k-{i}", i)
    assert len(lru) == 64
    assert lru.get("k-0") is None
    assert lru.get("k-499") == 499


# ---------------------------------------------------------------------------
# 3. 50 Concurrent Cart Additions (Atomic Upsert, Zero Duplicates, Stock Cap)
# ---------------------------------------------------------------------------

class _FakeCartTableQuery:
    def __init__(self, store: dict[tuple[int, int, str], dict[str, Any]], lock: threading.Lock):
        self._store = store
        self._lock = lock
        self._op = "select"
        self._filters: dict[str, Any] = {}
        self._payload: Any = None

    def select(self, *_a, **_kw):
        self._op = "select"
        return self

    def eq(self, col: str, val: Any):
        self._filters[col] = val
        return self

    def limit(self, _n: int):
        return self

    def upsert(self, payload: Any, on_conflict: str = ""):
        self._op = "upsert"
        self._payload = payload
        return self

    def delete(self):
        self._op = "delete"
        return self

    def execute(self):
        with self._lock:
            if self._op == "select":
                matched = [
                    dict(row)
                    for row in self._store.values()
                    if all(row.get(k) == v for k, v in self._filters.items())
                ]
                return SimpleNamespace(data=matched)
            if self._op == "upsert":
                rows = self._payload if isinstance(self._payload, list) else [self._payload]
                out = []
                for r in rows:
                    key = (int(r["user_id"]), int(r["product_id"]), str(r.get("selected_variant") or ""))
                    self._store[key] = dict(r)
                    out.append(dict(r))
                return SimpleNamespace(data=out)
            if self._op == "delete":
                to_del = [
                    k for k, row in self._store.items()
                    if all(row.get(fk) == fv for fk, fv in self._filters.items())
                ]
                for k in to_del:
                    self._store.pop(k, None)
                return SimpleNamespace(data=[])
        return SimpleNamespace(data=[])


def test_03_50_concurrent_cart_additions_atomic_upsert_and_stock_cap(monkeypatch):
    cart_store: dict[tuple[int, int, str], dict[str, Any]] = {}
    cart_lock = threading.Lock()

    fake_product = {
        "id": 990501,
        "name": "Limited Arctic Chrono",
        "description": "Precision watch",
        "price": 129.0,
        "image_url": "https://example.com/watch.png",
        "category": "Watches",
        "rating": 4.7,
        "reviews": 5,
        "stock": 35,
        "is_featured": False,
    }

    class _FakeClient:
        def table(self, name: str):
            assert name == "cart_items"
            return _FakeCartTableQuery(cart_store, cart_lock)

    monkeypatch.setattr(supabase_rest, "is_pg_tcp_reachable", lambda: False)
    monkeypatch.setattr(supabase_rest, "get_supabase_client", lambda: _FakeClient())
    monkeypatch.setattr(
        supabase_rest,
        "fetch_live_product_row_https",
        lambda pid: dict(fake_product) if int(pid) == 990501 else None,
    )
    monkeypatch.setattr(
        supabase_rest,
        "fetch_product_by_id_https",
        lambda pid: dict(fake_product) if int(pid) == 990501 else None,
    )

    shopper = _fake_user(7701, "cartstress@penguinstore.co")
    app.dependency_overrides[get_current_user] = lambda: shopper

    async def _fire_50_cart_adds():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
            async def _add_one(i: int):
                return await ac.post(
                    "/api/v1/cart/",
                    json={"product_id": 990501, "quantity": 1, "selected_variant": "Standard Edition"},
                    headers={"X-Forwarded-For": f"10.55.0.{(i % 200) + 1}"},
                )

            resps = await asyncio.gather(*[_add_one(i) for i in range(50)])
            cart_get = await ac.get("/api/v1/cart/", headers={"X-Forwarded-For": "10.55.1.1"})
            return resps, cart_get

    resps, cart_get = asyncio.run(_fire_50_cart_adds())
    ok_count = sum(1 for r in resps if r.status_code == 200)
    capped_count = sum(1 for r in resps if r.status_code == 400)

    assert ok_count == 35, f"Expected exactly 35 stock-allowed additions, got {ok_count}"
    assert capped_count == 15, f"Expected 15 stock-capped 400 rejections, got {capped_count}"
    assert len(cart_store) == 1, "Atomic upsert must never create duplicate (user, product, variant) rows"

    cart_json = cart_get.json()
    assert len(cart_json["items"]) == 1
    assert cart_json["items"][0]["quantity"] == 35


# ---------------------------------------------------------------------------
# 4. Concurrent Race-Condition Stock Checkout + Rollback + Idempotency-Key
# ---------------------------------------------------------------------------

class _FakeInventoryAndOrderClient:
    def __init__(self, stocks: dict[int, int], fail_rpc: bool = True):
        self.stocks = stocks
        self.lock = threading.Lock()
        self.orders: list[dict[str, Any]] = []
        self.order_items: list[dict[str, Any]] = []
        self._fail_rpc = fail_rpc

    def rpc(self, fn_name: str, params: dict[str, Any]):
        if self._fail_rpc:
            raise RuntimeError("Simulated PostgREST RPC fallback to CAS")
        client = self

        class _RpcExec:
            def execute(self_inner):
                with client.lock:
                    pid = int(params["p_product_id"])
                    qty = int(params["p_qty"])
                    if fn_name == "decrement_stock_atomic":
                        cur = client.stocks.get(pid, 0)
                        if cur < qty:
                            return SimpleNamespace(data=-1)
                        client.stocks[pid] = cur - qty
                        return SimpleNamespace(data=client.stocks[pid])
                    if fn_name == "increment_stock_atomic":
                        client.stocks[pid] = client.stocks.get(pid, 0) + qty
                        return SimpleNamespace(data=client.stocks[pid])
                return SimpleNamespace(data=None)

        return _RpcExec()

    def table(self, table_name: str):
        client = self

        class _Tbl:
            def __init__(self):
                self._op = "select"
                self._eq: dict[str, Any] = {}
                self._payload: Any = None

            def select(self, *_a, **_kw):
                self._op = "select"
                return self

            def eq(self, k: str, v: Any):
                self._eq[k] = v
                return self

            def limit(self, _n: int):
                return self

            def update(self, payload: dict[str, Any]):
                self._op = "update"
                self._payload = payload
                return self

            def insert(self, payload: Any):
                self._op = "insert"
                self._payload = payload
                return self

            def execute(self):
                with client.lock:
                    if table_name == "products":
                        pid = int(self._eq["id"])
                        cur = client.stocks.get(pid, 0)
                        if self._op == "select":
                            return SimpleNamespace(
                                data=[{"id": pid, "stock": cur, "is_active": True}]
                            )
                        if self._op == "update":
                            if "stock" in self._eq and int(self._eq["stock"]) != cur:
                                return SimpleNamespace(data=[])
                            new_val = int(self._payload["stock"])
                            if new_val < 0:
                                return SimpleNamespace(data=[])
                            client.stocks[pid] = new_val
                            return SimpleNamespace(data=[{"id": pid, "stock": new_val}])
                    elif table_name == "orders" and self._op == "insert":
                        oid = 50000 + len(client.orders) + 1
                        rec = {"id": oid, **self._payload}
                        client.orders.append(rec)
                        return SimpleNamespace(data=[rec])
                    elif table_name == "order_items" and self._op == "insert":
                        rows = self._payload if isinstance(self._payload, list) else [self._payload]
                        client.order_items.extend(rows)
                        return SimpleNamespace(data=rows)
                return SimpleNamespace(data=[])

        return _Tbl()


def test_04_race_condition_stock_checkout_zero_oversell_and_idempotency(monkeypatch):
    fake_db = _FakeInventoryAndOrderClient(stocks={990601: 3, 990602: 1}, fail_rpc=False)

    def _live_lookup(pid: int):
        pid_i = int(pid)
        if pid_i not in fake_db.stocks:
            return None
        return {
            "id": pid_i,
            "name": f"Flash Drop Item #{pid_i}",
            "price": 50.0,
            "category": "Electronics",
            "stock": fake_db.stocks[pid_i],
            "is_active": True,
            "fulfillment_type": "IN_HOUSE",
        }

    monkeypatch.setattr(orders_router, "is_pg_tcp_reachable", lambda: False)
    monkeypatch.setattr(orders_router, "get_supabase_client", lambda: fake_db)
    monkeypatch.setattr(orders_router, "fetch_live_product_row_https", _live_lookup)
    monkeypatch.setattr(orders_router, "send_order_confirmation", lambda *_a, **_kw: False)

    # Part A: 25 simultaneous buyers competing for 3 remaining units of #990601
    async def _run_25_buyers():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
            async def _buy(idx: int):
                return await ac.post(
                    "/api/orders/checkout",
                    json={
                        "customer_name": f"Buyer {idx}",
                        "customer_email": f"buyer{idx}@penguinstore.co",
                        "shipping_address": "100 Main Blvd",
                        "city": "Lahore",
                        "postal_code": "54000",
                        "payment_method": "COD",
                        "items": [{"product_id": 990601, "quantity": 1}],
                    },
                    headers={"X-Forwarded-For": f"10.66.0.{idx + 2}"},
                )

            return await asyncio.gather(*[_buy(i) for i in range(25)])

    responses = asyncio.run(_run_25_buyers())
    succeeded = [r for r in responses if r.status_code == 200]
    rejected = [r for r in responses if r.status_code == 400]

    assert len(succeeded) == 3, f"Expected exactly 3 orders to succeed for stock=3, got {len(succeeded)}"
    assert len(rejected) == 22, f"Expected 22 clean HTTP 400 out-of-stock responses, got {len(rejected)}"
    assert fake_db.stocks[990601] == 0, f"Stock must end at 0 (never negative!), got {fake_db.stocks[990601]}"

    # Part B: Multi-item atomic rollback when 2nd item fails stock decrement mid-transaction
    fake_db.stocks[990601] = 2
    fake_db.stocks[990602] = 0
    orig_dec = orders_router.decrement_stock_atomic

    # Simulate #990602 passing pre-check with stock=1 then losing race right before decrement
    def _stale_then_race_lookup(pid: int):
        row = _live_lookup(pid)
        if row and int(pid) == 990602:
            row["stock"] = 1
        return row

    monkeypatch.setattr(orders_router, "fetch_live_product_row_https", _stale_then_race_lookup)
    with TestClient(app) as tc:
        rb_res = tc.post(
            "/api/orders/checkout",
            json={
                "customer_name": "Rollback Buyer",
                "customer_email": "rollback@penguinstore.co",
                "shipping_address": "12 Park St",
                "city": "Islamabad",
                "postal_code": "44000",
                "payment_method": "COD",
                "items": [
                    {"product_id": 990601, "quantity": 1},
                    {"product_id": 990602, "quantity": 1},
                ],
            },
            headers={"X-Forwarded-For": "10.66.2.1"},
        )
        assert rb_res.status_code == 400
        assert fake_db.stocks[990601] == 2, "First item stock must be rolled back to 2 when second item fails!"

    monkeypatch.setattr(orders_router, "fetch_live_product_row_https", _live_lookup)
    monkeypatch.setattr(orders_router, "decrement_stock_atomic", orig_dec)

    # Part C: Idempotency-Key header prevents duplicate orders & double stock deduction
    fake_db.stocks[990601] = 5
    idem_key = "qa-idem-checkout-key-2026-001"
    checkout_body = {
        "customer_name": "Idempotent Shopper",
        "customer_email": "idem@penguinstore.co",
        "shipping_address": "88 Clifton Rd",
        "city": "Karachi",
        "postal_code": "75600",
        "payment_method": "COD",
        "items": [{"product_id": 990601, "quantity": 2}],
    }
    with TestClient(app) as tc:
        r1 = tc.post(
            "/api/orders/checkout",
            json=checkout_body,
            headers={"Idempotency-Key": idem_key, "X-Forwarded-For": "10.66.3.1"},
        )
        r2 = tc.post(
            "/api/orders/checkout",
            json=checkout_body,
            headers={"Idempotency-Key": idem_key, "X-Forwarded-For": "10.66.3.1"},
        )
        assert r1.status_code == 200 and r2.status_code == 200
        assert r1.json()["order_id"] == r2.json()["order_id"]
        assert r2.json().get("idempotent_replay") is True
        assert fake_db.stocks[990601] == 3, "Idempotent replay must NOT double-decrement stock (5 - 2 = 3)"


# ---------------------------------------------------------------------------
# 5. Flagship Review System: Zero-Template Tiers, Verified Purchase & CRUD
# ---------------------------------------------------------------------------

def test_05_reviews_zero_template_tiers_verified_purchase_crud_and_helpful_votes(monkeypatch):
    sqlite_engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=sqlite_engine)
    TestingSession = sessionmaker(autocommit=False, autoflush=False, bind=sqlite_engine)

    def _override_db():
        db = TestingSession()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = _override_db
    monkeypatch.setattr(commerce_ep, "_HAS_HELPFUL_TABLE", False)
    monkeypatch.setattr(
        supabase_rest,
        "fetch_product_by_id_https",
        lambda pid: {"id": 8801, "name": "Studio ANC Headphones", "price": 199.0} if int(pid) == 8801 else None,
    )
    monkeypatch.setattr(
        supabase_rest,
        "get_supabase_client",
        lambda: SimpleNamespace(
            table=lambda *_a, **_kw: SimpleNamespace(
                update=lambda *_x, **_y: SimpleNamespace(eq=lambda *_m, **_n: SimpleNamespace(execute=lambda: None)),
                select=lambda *_x, **_y: SimpleNamespace(
                    ilike=lambda *_m, **_n: SimpleNamespace(
                        order=lambda *_p, **_q: SimpleNamespace(
                            limit=lambda *_u, **_v: SimpleNamespace(execute=lambda: SimpleNamespace(data=[]))
                        )
                    )
                ),
            )
        ),
    )

    with TestingSession() as db:
        db.add(
            Product(
                id=8801,
                name="Studio ANC Headphones",
                description="Active noise cancelling wireless headphones",
                price=199.0,
                image_url="https://example.com/anc.png",
                category="Electronics",
                rating=0.0,
                reviews=0,
                stock=25,
            )
        )
        db.add_all(
            [
                User(id=11, email="verified_buyer@test.com", hashed_password="x", role="customer", is_active=True),
                User(id=12, email="pending_unpaid@test.com", hashed_password="x", role="customer", is_active=True),
                User(id=13, email="third_reviewer@test.com", hashed_password="x", role="customer", is_active=True),
            ]
        )
        db.commit()

    # Seed in-memory orders: user 11 has a PAID order; user 12 only has an UNPAID pending Stripe session
    with orders_router._MEM_ORDERS_LOCK:
        orders_router._MEM_ORDERS.appendleft(
            {
                "id": 91001,
                "order_id": 91001,
                "customer_email": "verified_buyer@test.com",
                "payment_status": "paid",
                "items": [{"product_id": 8801, "quantity": 1, "dispatch_status": "QUEUED_FOR_PACKING"}],
            }
        )
        orders_router._MEM_ORDERS.appendleft(
            {
                "id": 91002,
                "order_id": 91002,
                "customer_email": "pending_unpaid@test.com",
                "payment_status": "pending",
                "items": [{"product_id": 8801, "quantity": 1, "dispatch_status": "AWAITING_PAYMENT"}],
            }
        )

    with TestClient(app) as tc:
        # A) 0-Review Honest State: NO fake 4.8 rating, NO canned pros/cons/percentages
        r0 = tc.get("/api/v1/products/8801/reviews")
        assert r0.status_code == 200
        b0 = r0.json()
        assert b0["total_reviews"] == 0
        assert b0["average_rating"] == 0.0

        with TestingSession() as db:
            ins0 = get_or_generate_product_review_insights(db, 8801, force_refresh=True)
            assert ins0["has_insights"] is False
            assert ins0["sample_tier"] == "no_reviews"
            assert ins0["summary"]["pros"] == []
            assert ins0["summary"]["cons"] == []
            assert ins0["aspect_sentiment_bars"] == {}

        # B) Verified Buyer submits review -> 201 + verified_purchase == True
        buyer1 = _fake_user(11, "verified_buyer@test.com")
        app.dependency_overrides[get_current_user] = lambda: buyer1
        app.dependency_overrides[get_optional_current_user] = lambda: buyer1

        post1 = tc.post(
            "/api/v1/products/8801/reviews",
            json={
                "rating": 5,
                "title": "Phenomenal build quality and battery life",
                "comment": "Sound quality is crystal clear, battery lasts 30 hours, and shipping was super fast!",
                "tags": ["Premium Build", "Great Value"],
            },
        )
        assert post1.status_code == 201, post1.text
        rev1 = post1.json()
        assert rev1["verified_purchase"] is True
        assert "Premium Build" in rev1["tags"]
        assert "Verified Purchase" in rev1["trust_reasons"]
        rev1_id = rev1["id"]

        # Duplicate review by same user -> 409 Conflict
        dup = tc.post(
            "/api/v1/products/8801/reviews",
            json={"rating": 4, "comment": "Trying to post a second review on same product."},
        )
        assert dup.status_code == 409

        # C) 1-Review Tier -> `early_feedback` (honest sample badge, zero overstated aspect percentages)
        with TestingSession() as db:
            ins1 = get_or_generate_product_review_insights(db, 8801, force_refresh=True)
            assert ins1["has_insights"] is True
            assert ins1["sample_tier"] == "early_feedback"
            assert "Early Feedback" in (ins1.get("early_feedback_badge") or "")
            assert ins1["aspect_sentiment_bars"] == {}
            assert len(ins1["summary"]["pros"]) == 1
            assert "Verified buyer:" in ins1["summary"]["pros"][0]

        # D) Unpaid pending user submits review -> `verified_purchase` MUST be False!
        buyer2 = _fake_user(12, "pending_unpaid@test.com")
        app.dependency_overrides[get_current_user] = lambda: buyer2
        app.dependency_overrides[get_optional_current_user] = lambda: buyer2

        post2 = tc.post(
            "/api/v1/products/8801/reviews",
            json={
                "rating": 4,
                "title": "Comfortable ear pads",
                "comment": "Tried these in studio — solid build quality and good value for the price.",
            },
        )
        assert post2.status_code == 201
        assert post2.json()["verified_purchase"] is False

        # Ownership enforcement: buyer2 cannot edit or delete buyer1's review -> 403
        assert tc.put(
            f"/api/v1/products/8801/reviews/{rev1_id}",
            json={"rating": 1, "comment": "Unauthorized edit attempt"},
        ).status_code == 403
        assert tc.delete(f"/api/v1/products/8801/reviews/{rev1_id}").status_code == 403

        # Idempotent Helpful Vote Toggle by buyer2 on rev1: 1 -> 0 -> 1
        h1 = tc.post(f"/api/v1/reviews/{rev1_id}/helpful")
        assert h1.status_code == 200 and h1.json()["helpful"] is True and h1.json()["helpful_count"] == 1
        h2 = tc.post(f"/api/v1/reviews/{rev1_id}/helpful")
        assert h2.status_code == 200 and h2.json()["helpful"] is False and h2.json()["helpful_count"] == 0
        h3 = tc.post(f"/api/v1/reviews/{rev1_id}/helpful")
        assert h3.status_code == 200 and h3.json()["helpful"] is True and h3.json()["helpful_count"] == 1

        # E) 3rd Reviewer -> Unlocks `full_insights` grounded synthesis
        buyer3 = _fake_user(13, "third_reviewer@test.com")
        app.dependency_overrides[get_current_user] = lambda: buyer3
        post3 = tc.post(
            "/api/v1/products/8801/reviews",
            json={
                "rating": 5,
                "title": "Worth every dollar",
                "comment": "Excellent quality materials, accurate fit, and fast delivery packaging.",
                "tags": ["Fast Shipping"],
            },
        )
        assert post3.status_code == 201

        with TestingSession() as db:
            ins3 = get_or_generate_product_review_insights(db, 8801, force_refresh=True)
            assert ins3["has_insights"] is True
            assert ins3["sample_tier"] == "full_insights"
            assert ins3["total_reviews"] == 3
            assert len(ins3["aspect_sentiment_bars"]) >= 1
            assert len(ins3["summary"]["verdict"]) > 10

        # F) Buyer 1 edits & then deletes own review cleanly
        app.dependency_overrides[get_current_user] = lambda: buyer1
        upd1 = tc.put(
            f"/api/v1/products/8801/reviews/{rev1_id}",
            json={
                "rating": 5,
                "title": "Updated after 2 weeks",
                "comment": "Still 5 stars after daily travel use — battery and ANC quality are top tier.",
                "tags": ["True to Specs"],
            },
        )
        assert upd1.status_code == 200
        assert upd1.json()["title"] == "Updated after 2 weeks"

        del1 = tc.delete(f"/api/v1/products/8801/reviews/{rev1_id}")
        assert del1.status_code == 200 and del1.json()["deleted"] is True
        assert del1.json()["total_reviews"] == 2

    global_single_flight.invalidate_prefix("review_insights:8801")


# ---------------------------------------------------------------------------
# 6. Voice Search Hallucination Filter, Spoken Prices & Fuzzy Catalog Repair
# ---------------------------------------------------------------------------

def test_06_voice_hallucination_guard_spoken_prices_and_fuzzy_catalog_repair():
    # A) Short/silent byte upload returns graceful empty_clip JSON (never 500)
    with TestClient(app) as tc:
        res = tc.post(
            "/api/v1/ai/transcribe",
            files={"file": ("recording.webm", b"\x00" * 120, "audio/webm")},
        )
        assert res.status_code == 200
        data = res.json()
        assert data["empty_clip"] is True
        assert data["transcript"] == ""
        assert "mic" in data["message"].lower()

    # B) Hallucination & silence filter unit checks
    assert is_whisper_hallucination_or_silence("Thank you.") is True
    assert is_whisper_hallucination_or_silence("Thanks for watching!") is True
    assert is_whisper_hallucination_or_silence("Subtitles by Amara.org") is True
    assert is_whisper_hallucination_or_silence("...") is True
    assert is_whisper_hallucination_or_silence("shoes", duration_seconds=0.20) is True
    assert is_whisper_hallucination_or_silence("okay", avg_no_speech_prob=0.92) is True
    assert is_whisper_hallucination_or_silence("AirPods Pro", duration_seconds=1.1) is False
    assert is_whisper_hallucination_or_silence("wireless headphones under $250", duration_seconds=1.8) is False

    # C) Spoken number normalization & Catalog-Aware Post-ASR Query Repair
    assert normalize_spoken_numbers("shoes under two fifty") == "shoes under $250"
    assert normalize_spoken_numbers("watches below one hundred dollars") == "watches below $100"

    sample_catalog = [
        {"name": "Apple AirPods Max Studio", "category": "Electronics"},
        {"name": "Urban Runner Sneakers", "category": "Men Shoes"},
        {"name": "Chrono Pro Smartwatch", "category": "Watches"},
    ]

    rep1 = repair_voice_query("ear pods under two fifty.", catalog_products=sample_catalog)
    assert rep1["transcript"] == "AirPods under $250"
    assert rep1["inferred_max_price"] == 250.0
    assert rep1["was_repaired"] is True

    rep2 = repair_voice_query("three d smart watch below one hundred dollars", catalog_products=sample_catalog)
    assert rep2["transcript"] == "3D smartwatch below $100"
    assert rep2["inferred_max_price"] == 100.0
    assert rep2["inferred_only_3d"] is True

    rep3 = repair_voice_query("sneekers under fifty bucks", catalog_products=sample_catalog)
    assert "sneakers" in rep3["transcript"].lower()
    assert rep3["inferred_max_price"] == 50.0

    # D) Main hybrid search bar honors inline spoken budgets
    priced_hits = supabase_rest.search_products_hybrid_https(search="shoes under two fifty", limit=20)
    assert all(float(p["price"]) <= 250.0 for p in priced_hits)


# ---------------------------------------------------------------------------
# 7. Visual Search Preprocessing (EXIF + Alpha->White) & Calibrated Tiers
# ---------------------------------------------------------------------------

def test_07_visual_preprocessing_alpha_white_exif_and_calibrated_tiers(monkeypatch):
    # A) Transparent RGBA PNG -> White (255, 255, 255) canvas compositing (NEVER black!)
    rgba = Image.new("RGBA", (100, 100), (0, 0, 0, 0))
    for x in range(30, 70):
        for y in range(30, 70):
            rgba.putpixel((x, y), (220, 40, 40, 255))
    png_buf = io.BytesIO()
    rgba.save(png_buf, format="PNG")

    clean_rgb = prepare_clean_rgb_image(png_buf.getvalue())
    assert clean_rgb.mode == "RGB"
    assert clean_rgb.getpixel((0, 0)) == (255, 255, 255), "Transparent alpha pixels must composite onto white!"
    assert clean_rgb.getpixel((50, 50)) == (220, 40, 40)

    # B) EXIF Orientation=6 (90° CW) auto-transpose check
    rect_img = Image.new("RGB", (80, 160), (30, 90, 200))
    exif = Image.Exif()
    exif[0x0112] = 6  # Orientation: Rotate 90 CW -> transposed size must become (160, 80)
    jpg_buf = io.BytesIO()
    rect_img.save(jpg_buf, format="JPEG", exif=exif.tobytes())
    transposed_rgb = prepare_clean_rgb_image(jpg_buf.getvalue())
    assert transposed_rgb.size == (160, 80), f"EXIF Orientation=6 must transpose (80,160)->(160,80), got {transposed_rgb.size}"

    # C) Standardized 256 -> 224x224 center crop & tiny image rejection
    cropped = standardize_resnet_crop(transposed_rgb, resize_shortest=256, crop_size=224)
    assert cropped.size == (224, 224)

    tiny_buf = io.BytesIO()
    Image.new("RGB", (8, 8), (255, 0, 0)).save(tiny_buf, format="PNG")
    with pytest.raises(ValueError, match="too small"):
        prepare_clean_rgb_image(tiny_buf.getvalue())

    # D) Calibrated Confidence Tiers & Multimodal RRF Anti-Inflation Proof
    assert classify_visual_confidence(0.84) == ("strong_match", "Strong Match")
    assert classify_visual_confidence(0.91) == ("strong_match", "Exact Match")
    assert classify_visual_confidence(0.62) == ("similar_style", "Similar Style")
    assert classify_visual_confidence(0.39) == ("closest_alternatives", "Closest Alternative")

    # Prove weak visual similarity (~0.35) is NEVER inflated to 99% in Multimodal RRF
    q_vec = np.zeros(2048, dtype=np.float32)
    q_vec[0] = 1.0
    cat_vec = np.zeros(2048, dtype=np.float32)
    cat_vec[0] = 0.35
    cat_vec[1] = float(np.sqrt(1.0 - 0.35**2))

    fake_cat_prod = {
        "id": 77101,
        "name": "Minimalist Leather Loafers",
        "description": "Classic footwear",
        "price": 120.0,
        "image_url": "https://example.com/loafer.jpg",
        "category": "Men Shoes",
        "rating": 4.5,
        "reviews": 4,
        "stock": 8,
    }
    monkeypatch.setattr(mm_service, "fetch_products_https", lambda: [dict(fake_cat_prod)])
    monkeypatch.setattr(mm_service, "fetch_3d_catalog_ids_https", lambda: [])
    monkeypatch.setattr(
        mm_service,
        "analyze_and_embed_query",
        lambda _b: {
            "primary_vector": q_vec.tolist(),
            "variant_vectors": [q_vec.tolist()],
            "variant_weights": [1.0],
            "was_deblurred": False,
            "is_heavily_blurred": False,
            "sharpness_score": 450.0,
            "is_blank_or_noise": False,
        },
    )
    from app.routers import visual_search as vs_router

    monkeypatch.setattr(
        vs_router._catalog_cache,
        "get_catalog",
        lambda: ([dict(fake_cat_prod)], np.vstack([cat_vec])),
    )

    out = mm_service.execute_multimodal_rrf_search(image_bytes=png_buf.getvalue())
    assert len(out["matches"]) == 1
    top_match = out["matches"][0]
    assert top_match["score"] < 0.55, f"Weak 0.35 similarity must NOT inflate to >=0.55, got {top_match['score']}"
    assert top_match["confidence_tier"] == "closest_alternatives"
    assert top_match["match_label"] == "Closest Alternative"
    assert "closest styles currently in stock" in out["search_summary"]
    assert "In Stock" in top_match["match_reason"]
