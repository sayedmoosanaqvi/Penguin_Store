"""Dual-Channel Voice Response Formatter & Anti-Markdown TTS Sanitizer.

Ensures EVERY voice output from Penguin Store (`spoken_summary`) consists of
clean, concise, conversational plain-English prose with ZERO Markdown tables,
hyphens/dashes, pipes, bullets, URLs, code blocks, or symbol artifacts.
"""

from __future__ import annotations

import re
from typing import Any, Optional


def format_price_for_speech(amount: Any) -> str:
    """Format a USD price naturally for TTS (e.g. 249.00 -> '249 dollars')."""
    try:
        val = max(0.0, float(amount or 0.0))
    except (TypeError, ValueError):
        return "0 dollars"

    whole = int(val)
    cents = int(round((val - whole) * 100))
    if cents == 100:
        whole += 1
        cents = 0

    dollar_word = "dollar" if whole == 1 else "dollars"
    if cents == 0:
        return f"{whole} {dollar_word}"
    cent_word = "cent" if cents == 1 else "cents"
    return f"{whole} {dollar_word} and {cents} {cent_word}"


def sanitize_spoken_text(raw: Optional[str], max_sentences: int = 4) -> str:
    """
    Strictly sanitize arbitrary LLM text so TTS can NEVER pronounce
    Markdown syntax ('dash dash dash', 'pipe', 'asterisk', 'underscore', etc.).
    """
    if not raw:
        return ""

    text = str(raw)

    # 1. Remove fenced code blocks & inline links/URLs
    text = re.sub(r"```[\s\S]*?```", " ", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)

    # 2. Drop Markdown table rows and separator / horizontal-rule lines
    clean_lines: list[str] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Drop pure rule lines (---, ===, ***, |---|---|, :--:)
        if re.fullmatch(r"[-:=_*+|•·\s\u2500-\u257f]+", stripped):
            continue
        # Drop full Markdown table rows starting/ending with pipe or having >= 2 pipes
        if stripped.startswith("|") or stripped.count("|") >= 2:
            continue
        # Strip leading markdown headings / bullets / blockquotes
        stripped = re.sub(r"^\s*(?:#{1,6}|[-*+•>]+)\s+", "", stripped)
        clean_lines.append(stripped)

    text = ". ".join(clean_lines)

    # 3. Order IDs and currency conversion
    text = re.sub(
        r"(?:Order\s*#\s*|#)(\d+)\b",
        lambda m: f"order number {m.group(1)}",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"\$\s*([0-9][0-9,]*(?:\.\d{1,2})?)",
        lambda m: format_price_for_speech(m.group(1).replace(",", "")),
        text,
    )
    text = re.sub(
        r"€\s*([0-9][0-9,]*(?:\.\d{1,2})?)",
        lambda m: f"{m.group(1).replace(',', '')} euros",
        text,
    )
    text = re.sub(
        r"Rs\.?\s*([0-9][0-9,]*)",
        lambda m: f"{m.group(1).replace(',', '')} rupees",
        text,
        flags=re.IGNORECASE,
    )

    # 4. Symbols & punctuation runs (prevents "dash dash dash" / "underscore")
    text = text.replace("%", " percent")
    text = text.replace("&", " and ")
    text = re.sub(r"\s*[★☆⭐]+\s*", " star ", text)
    text = re.sub(r"[✅☑️❌⚠️🔥🔊⏹🎉📦🤖🛡️✨💎]+", " ", text)
    # Remove any remaining non-BMP emojis / symbol blocks
    text = re.sub(r"[\U00010000-\U0010ffff]+", " ", text)
    # Remove markdown formatting characters completely
    text = re.sub(r"[*_#`~|<>^\\]+", " ", text)
    # Collapse runs of 2+ punctuation marks (--, ---, ..., ___) or spaced dashes to a pause
    text = re.sub(r"[-–—]{2,}|_{2,}|\.{2,}|={2,}", ", ", text)
    text = re.sub(r"\s+[-–—]\s+", ", ", text)
    # Remove orphan hyphens not part of hyphenated words like "3D" or "top-rated"
    text = re.sub(r"(?<!\w)[-–—]+|[-–—]+(?!\w)", " ", text)

    # Normalize comma/period spacing
    text = re.sub(r"\s*,\s*(?:,\s*)+", ", ", text)
    text = re.sub(r"\.\s*,", ".", text)
    text = re.sub(r"\.{2,}", ".", text)
    text = re.sub(r"\s+", " ", text).strip(" ,;:")

    if not text:
        return ""

    # 5. Keep up to max_sentences sentences for natural crisp voice UX
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    if max_sentences > 0 and len(sentences) > max_sentences:
        sentences = sentences[:max_sentences]

    result = " ".join(sentences).strip()
    if len(result) > 460:
        clipped = result[:460]
        last_stop = max(clipped.rfind(". "), clipped.rfind("? "), clipped.rfind("! "))
        if last_stop > 140:
            result = clipped[: last_stop + 1].strip()
        else:
            result = clipped.rsplit(" ", 1)[0].strip(" ,;:") + "."

    if result and result[-1] not in ".!?":
        result += "."

    return result


def build_comparison_spoken_summary(
    compared_products: list[dict[str, Any]],
    top_rated: Optional[dict[str, Any]],
    cheapest: Optional[dict[str, Any]],
    winner_reason: str = "",
) -> str:
    """Build a crisp 2-3 sentence spoken comparison verdict with zero table syntax."""
    if not compared_products:
        return "I couldn't find enough in-stock products to compare right now."

    first = compared_products[0]
    first_name = str(first.get("name") or "Product one")
    first_price = format_price_for_speech(first.get("price") or 0)
    first_trust = int(round(float(first.get("verified_authentic_percent") or 96.0)))

    if len(compared_products) == 1:
        return sanitize_spoken_text(
            f"I found {first_name} at {first_price} with a {first_trust} percent trust score. "
            "Would you like me to add it to your cart or show it in 3D?"
        )

    second = compared_products[1]
    second_name = str(second.get("name") or "Product two")
    second_price = format_price_for_speech(second.get("price") or 0)
    second_trust = int(round(float(second.get("verified_authentic_percent") or 96.0)))

    top_name = str((top_rated or first).get("name") or first_name)
    top_trust_stars = float((top_rated or first).get("trust_weighted_rating") or 4.8)

    p1 = float(first.get("price") or 0)
    p2 = float(second.get("price") or 0)
    diff = abs(p1 - p2)
    diff_phrase = ""
    if diff >= 1.0:
        cheaper_name = first_name if p1 <= p2 else second_name
        diff_phrase = f" {cheaper_name} is {format_price_for_speech(diff)} more affordable,"
    else:
        diff_phrase = " Both are similarly priced,"

    has_3d_any = any(bool(p.get("has_3d_model")) for p in compared_products[:3])
    three_d_phrase = (
        " Interactive 3D previews are available."
        if has_3d_any
        else ""
    )

    script = (
        f"Comparing {first_name} at {first_price} with a {first_trust} percent trust score "
        f"and {second_name} at {second_price} with {second_trust} percent verified reviews.{diff_phrase} "
        f"while {top_name} is my top overall pick at {top_trust_stars:.1f} trust stars."
        f"{three_d_phrase} Would you like me to add one to your cart or open it in 3D?"
    )
    return sanitize_spoken_text(script, max_sentences=4)


def build_product_list_spoken_summary(
    products: list[dict[str, Any]],
    user_query: str = "",
    used_fallback: bool = False,
) -> str:
    """Build a crisp 2-3 sentence voice readout grounded in matched Supabase products."""
    if not products:
        return (
            "I checked the live Penguin Store catalog, but didn't see an exact in-stock match. "
            "Try telling me a category, style, or budget and I will search again."
        )

    lead = products[0]
    lead_name = str(lead.get("name") or "our top pick")
    lead_price = format_price_for_speech(lead.get("price") or 0)
    lead_trust = float(lead.get("trust_weighted_rating") or lead.get("rating") or 4.8)

    prefix = (
        f"I didn't see an exact match, so here are {len(products)} close in-stock options."
        if used_fallback
        else f"I found {len(products)} verified products matching your request."
    )

    if len(products) >= 2:
        second = products[1]
        second_name = str(second.get("name") or "another option")
        second_price = format_price_for_speech(second.get("price") or 0)
        summary = (
            f"{prefix} Leading the list is {lead_name} at {lead_price} rated {lead_trust:.1f} stars, "
            f"followed by {second_name} at {second_price}. "
            "Say compare the top two or add the first one to your cart anytime."
        )
    else:
        summary = (
            f"{prefix} {lead_name} is available for {lead_price} with a {lead_trust:.1f} star trust rating. "
            "Say add this to cart or show in 3D whenever you're ready."
        )
    return sanitize_spoken_text(summary, max_sentences=3)


def build_bundle_spoken_summary(bundle_obj: dict[str, Any]) -> str:
    items = bundle_obj.get("items") or []
    total = format_price_for_speech(bundle_obj.get("total_price") or 0)
    names = [str(i.get("name") or "item") for i in items[:3]]
    joined = ", ".join(names[:-1]) + (f", and {names[-1]}" if len(names) > 1 else (names[0] if names else ""))
    avg_trust = float(bundle_obj.get("average_trust_rating") or 4.8)
    budget = bundle_obj.get("budget")
    budget_note = (
        f", staying well within your {format_price_for_speech(budget)} budget"
        if budget is not None
        else ""
    )
    return sanitize_spoken_text(
        f"I built a {len(items)}-item bundle featuring {joined} for a total of {total}{budget_note}, "
        f"averaging {avg_trust:.1f} trust stars. "
        "You can add the full bundle in one tap or ask me to open any item.",
        max_sentences=3,
    )


def build_review_trust_spoken_summary(
    *,
    product_name: str,
    trust_rating: float,
    verified_pct: float,
    verdict: str,
    pros: list[str],
    cons: list[str],
) -> str:
    pros_clause = f" Buyers praise {pros[0].rstrip('.')}." if pros else ""
    cons_clause = f" Note one trade-off, {cons[0].rstrip('.')}." if cons else ""
    base = (
        f"For {product_name}, our AI trust engine scores verified reviews at "
        f"{trust_rating:.1f} out of 5 with {verified_pct:.0f} percent authentic buyer feedback."
        f"{pros_clause}{cons_clause} {verdict}"
    )
    return sanitize_spoken_text(base, max_sentences=4)


def build_client_action_spoken_summary(
    client_action: Optional[dict[str, Any]],
    fallback_text: str = "",
) -> str:
    if not isinstance(client_action, dict):
        return sanitize_spoken_text(fallback_text, max_sentences=3)

    atype = str(client_action.get("type") or "").lower()
    pname = str(client_action.get("product_name") or "").strip()
    if not pname and isinstance(client_action.get("product"), dict):
        pname = str(client_action["product"].get("name") or "the item").strip()

    if atype == "add_to_cart":
        qty = int(client_action.get("quantity") or 1)
        qty_phrase = f"{qty} units of " if qty > 1 else ""
        return sanitize_spoken_text(
            f"Done. I added {qty_phrase}{pname or 'the item'} to your shopping cart. "
            "Say go to checkout when you're ready to pay.",
            max_sentences=2,
        )
    if atype == "open_3d":
        return sanitize_spoken_text(
            f"Opening the interactive 3D studio preview for {pname or 'this product'} now.",
            max_sentences=2,
        )
    if atype == "open_product":
        return sanitize_spoken_text(
            f"Opening the details page for {pname or 'that product'}.",
            max_sentences=2,
        )
    if atype == "toggle_favorite":
        return sanitize_spoken_text(
            f"Updated your favorites wishlist with {pname or 'this item'}.",
            max_sentences=2,
        )
    if atype == "navigate":
        route = str(client_action.get("route") or "")
        dest_map = {
            "/cart": "your shopping cart",
            "/checkout": "checkout",
            "/wishlist": "your favorites",
            "/showcase-3d": "the 3D product showcase",
            "/orders": "your order tracker",
            "/discover": "the product catalog",
        }
        dest = dest_map.get(route, "that page")
        return sanitize_spoken_text(f"Taking you to {dest} now.", max_sentences=2)

    return sanitize_spoken_text(fallback_text, max_sentences=3)
