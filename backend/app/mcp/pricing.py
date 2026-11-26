"""Authoritative deal/quote engine shared by MCP, CTRL-X and Stripe/COD checkout.

Every number here is derived from the SAME functions that price a real order in
`app.routers.orders`, so a price quoted by an agent is the price checkout charges.
"""

from __future__ import annotations

from typing import Any, Optional

from app.core.supabase_rest import fetch_product_by_id_https, is_product_active_row

PROMO_CODES: tuple[str, ...] = ("PENGUIN10", "WELCOME20", "WHOLESALE15", "B2BBULK", "ARCTIC5")

MOQ_TIERS: tuple[dict[str, Any], ...] = (
    {"tier": "Standard Retail (1-9 units)", "min_qty": 1, "max_qty": 9, "discount_pct": 0},
    {"tier": "Corporate Wholesale (10-49 units)", "min_qty": 10, "max_qty": 49, "discount_pct": 12},
    {"tier": "Enterprise Distributor (50+ units)", "min_qty": 50, "max_qty": None, "discount_pct": 22},
)

APPAREL_VARIANTS: tuple[tuple[str, float], ...] = (
    ("S — Standard Fit", 0.0),
    ("M — Standard Fit", 0.0),
    ("L — Standard Fit", 0.0),
    ("XL — Tailored Fit", 8.0),
    ("Pro Custom Fit", 18.0),
)
GENERAL_VARIANTS: tuple[tuple[str, float], ...] = (
    ("Standard Edition", 0.0),
    ("Pro Edition", 24.0),
    ("Collector Studio Edition", 45.0),
)
ADDON_CATALOG: tuple[dict[str, Any], ...] = (
    {"id": "gift_wrap", "title": "Gift Wrapping", "price": 9.99},
    {"id": "extended_warranty", "title": "Extended 2-Year Warranty", "price": 29.99},
    {"id": "express_handling", "title": "Priority Express Handling", "price": 14.50},
)


def is_apparel_category(category: str) -> bool:
    cat = (category or "").strip().lower()
    return any(
        kw in cat for kw in ("cloth", "fashion", "apparel", "wear", "jacket", "shoe", "foot")
    )


def variant_options(category: str, base_price: float) -> list[dict[str, Any]]:
    table = APPAREL_VARIANTS if is_apparel_category(category) else GENERAL_VARIANTS
    return [
        {
            "label": label,
            "price_delta": delta,
            "unit_price": round(float(base_price) + delta, 2),
        }
        for label, delta in table
    ]


def moq_tiers_for(unit_price: float) -> list[dict[str, Any]]:
    base = max(float(unit_price or 0.0), 0.0)
    return [
        {
            **tier,
            "unit_price": round(base * (1.0 - tier["discount_pct"] / 100.0), 2),
        }
        for tier in MOQ_TIERS
    ]


def _tier_label(qty: int) -> tuple[str, int]:
    for tier in reversed(MOQ_TIERS):
        if qty >= tier["min_qty"]:
            return tier["tier"], int(tier["discount_pct"])
    return MOQ_TIERS[0]["tier"], 0


def authoritative_deal_quote(
    product_id: int,
    quantity: int = 1,
    variant: Optional[str] = None,
    gift_wrap: bool = False,
    warranty: bool = False,
    promo_code: Optional[str] = None,
    product_row: Optional[dict[str, Any]] = None,
) -> Optional[dict[str, Any]]:
    """Return a quote matching `calculate_best_deal`'s key contract, or None if inactive."""
    from app.routers.orders import (
        _compute_addons_unit_delta,
        _compute_variant_delta,
        compute_authoritative_promo_discount,
    )

    prod = product_row or fetch_product_by_id_https(int(product_id))
    if prod is None or not is_product_active_row(prod):
        return None

    qty = max(1, min(int(quantity or 1), 1000))
    base = max(0.0, float(prod.get("price") or 0.0))
    category = str(prod.get("category") or "")
    chosen_variant = (variant or "").strip() or None
    variant_delta = _compute_variant_delta(category, chosen_variant)
    retail_unit = round(base + variant_delta, 2)

    tier_label, discount_pct = _tier_label(qty)
    b2b_unit = round(retail_unit * (1.0 - discount_pct / 100.0), 2)

    addons: list[str] = []
    if gift_wrap:
        addons.append("Gift Wrapping")
    if warranty:
        addons.append("Extended 2-Year Warranty")
    addon_unit = _compute_addons_unit_delta(addons)

    retail_subtotal = round(retail_unit * qty, 2)
    b2b_subtotal = round(b2b_unit * qty, 2)
    add_on_cost = round(addon_unit * qty, 2)
    b2b_savings = round(retail_subtotal - b2b_subtotal, 2)
    subtotal_after_b2b = round(b2b_subtotal + add_on_cost, 2)

    evaluated: list[dict[str, Any]] = []
    for code in PROMO_CODES:
        disc, applied = compute_authoritative_promo_discount(subtotal_after_b2b, code)
        evaluated.append({"code": code, "discount": disc, "applies": applied is not None})

    requested_code = (promo_code or "").strip().upper()
    if requested_code:
        disc, applied = compute_authoritative_promo_discount(subtotal_after_b2b, requested_code)
        best_code, promo_discount = (applied, disc)
        promo_desc = (
            f"{requested_code} applied" if applied else f"{requested_code} is not valid for this subtotal"
        )
    else:
        applicable = [e for e in evaluated if e["applies"] and e["discount"] > 0]
        best = max(applicable, key=lambda e: e["discount"]) if applicable else None
        best_code = best["code"] if best else None
        promo_discount = float(best["discount"]) if best else 0.0
        promo_desc = f"Best stackable promo: {best_code}" if best else "No promo code applies"

    discounted_subtotal = max(0.0, round(subtotal_after_b2b - promo_discount, 2))
    estimated_tax = round(discounted_subtotal * 0.05, 2)
    final_total = round(discounted_subtotal + estimated_tax, 2)
    total_savings = round(b2b_savings + promo_discount, 2)

    return {
        "product_id": int(product_id),
        "product_name": str(prod.get("name") or f"Product #{product_id}"),
        "quantity": qty,
        "variant": chosen_variant or "Standard",
        "variant_price_delta": variant_delta,
        "gift_wrap": bool(gift_wrap),
        "warranty": bool(warranty),
        "addons": addons,
        "retail_unit_price": retail_unit,
        "retail_subtotal": retail_subtotal,
        "b2b_tier_label": tier_label,
        "b2b_discount_pct": discount_pct,
        "b2b_unit_price": b2b_unit,
        "b2b_subtotal": b2b_subtotal,
        "b2b_savings": b2b_savings,
        "add_on_cost": add_on_cost,
        "best_promo_code": best_code,
        "promo_discount": round(promo_discount, 2),
        "promo_description": promo_desc,
        "all_promos_evaluated": evaluated,
        "discounted_subtotal": discounted_subtotal,
        "estimated_tax": estimated_tax,
        "final_total": final_total,
        "total_savings": total_savings,
        "authoritative": True,
        "pricing_source": "server_side_checkout_engine",
    }
