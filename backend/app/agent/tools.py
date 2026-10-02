import json
import logging
import re
from typing import Optional, Union

from langchain_core.tools import tool
from pydantic import BaseModel, Field
from sqlalchemy import or_
from sqlalchemy.orm import Session, load_only

from app.database import SessionLocal
from app.models import Product, Order, OrderItem
from app.agent.rag import retrieve_store_knowledge


# ===========================================================================
# LOGGING
# ===========================================================================

logger = logging.getLogger("uvicorn.error")


# ===========================================================================
# INTERNAL SEARCH HELPERS
# ===========================================================================

def _normalize_text(value: Optional[str]) -> str:
    """
    Normalize product/search text for lightweight relevance scoring.
    """

    if not value:
        return ""

    value = value.lower()

    # Examples:
    # MENS-SHIRTS -> mens shirts
    # WOMEN_ACCESSORIES -> women accessories
    value = re.sub(
        r"[^a-z0-9]+",
        " ",
        value,
    )

    return " ".join(
        value.split()
    )


def _search_tokens(
    value: Optional[str],
) -> list[str]:
    """
    Extract meaningful searchable terms while removing common
    conversational filler.
    """

    text = _normalize_text(
        value
    )

    if not text:
        return []

    stop_words = {
        "a",
        "an",
        "the",
        "and",
        "or",
        "for",
        "with",
        "to",
        "me",
        "my",
        "i",
        "want",
        "need",
        "show",
        "find",
        "looking",
        "something",
        "some",
        "product",
        "products",
        "item",
        "items",
    }

    return [
        token
        for token in text.split()
        if len(token) > 1
        and token not in stop_words
    ]


def _score_product(
    product: Product,
    search_term: Optional[str],
    category: Optional[str],
) -> float:
    """
    Lightweight product relevance score.

    Priority:
    1. Exact/category relevance
    2. Product-name relevance
    3. Description relevance
    4. Featured status as a small tie-breaker

    This avoids loading another AI model on the 512 MB Render server.
    """

    name = _normalize_text(
        product.name
    )

    product_category = _normalize_text(
        product.category
    )

    description = _normalize_text(
        product.description
    )

    search_text = _normalize_text(
        search_term
    )

    requested_category = _normalize_text(
        category
    )

    score = 0.0

    # -----------------------------------------------------------------------
    # Category relevance
    # -----------------------------------------------------------------------

    if requested_category:
        if requested_category == product_category:
            score += 30.0

        elif requested_category in product_category:
            score += 24.0

        category_tokens = _search_tokens(
            requested_category
        )

        for token in category_tokens:
            if token in product_category:
                score += 8.0

            if token in name:
                score += 3.0

    # -----------------------------------------------------------------------
    # Search-term relevance
    # -----------------------------------------------------------------------

    if search_text:
        if search_text in name:
            score += 30.0

        if search_text in product_category:
            score += 20.0

        if search_text in description:
            score += 12.0

        search_tokens = _search_tokens(
            search_text
        )

        for token in search_tokens:
            if token in name:
                score += 8.0

            if token in product_category:
                score += 6.0

            if token in description:
                score += 3.0

    # Small tie-breaker only.
    if product.is_featured:
        score += 1.0

    return score


def _product_to_public_dict(
    product: Product,
) -> dict:
    """
    Convert a Product ORM object into customer-safe JSON.

    Internal supplier information, cost prices, and embedding vectors
    are deliberately excluded.
    """

    return {
        "id": product.id,
        "name": product.name,
        "description": product.description,
        "price": product.price,
        "original_price": product.original_price,
        "image_url": product.image_url,
        "category": product.category,
        "rating": product.rating,
        "reviews": product.reviews,
        "discount_percent": product.discount_percent,
        "is_featured": product.is_featured,
        "stock": product.stock,
        "fulfillment_type": (
            product.fulfillment_type
            or "IN_HOUSE"
        ),
    }


# ===========================================================================
# PRODUCT SEARCH TOOL
# ===========================================================================

class ProductSearchInput(BaseModel):
    search_term: Optional[str] = Field(
        default=None,
        description=(
            "A product keyword, style, color, brand, material, occasion, "
            "or descriptive search term. Examples: black, floral, shirt, "
            "party, wedding, running, leather."
        ),
    )

    category: Optional[str] = Field(
        default=None,
        description=(
            "A product category that should be searched. "
            "Only use a category when reasonably confident it exists. "
            "If uncertain about the real catalog taxonomy, use "
            "inspect_catalog first."
        ),
    )

    max_price: Optional[float] = Field(
        default=None,
        description=(
            "Maximum price the customer is willing to pay."
        ),
    )

    is_featured: Optional[bool] = Field(
        default=None,
        description=(
            "Set to true only when the customer specifically requests "
            "featured, popular, or trending products."
        ),
    )


@tool(
    "search_inventory",
    args_schema=ProductSearchInput,
)
def search_inventory(
    search_term: Optional[str] = None,
    category: Optional[str] = None,
    max_price: Optional[float] = None,
    is_featured: Optional[bool] = None,
) -> str:
    """
    Search Penguin Store's live PostgreSQL product inventory.

    Use for:
    - product discovery
    - recommendations
    - price searches
    - categories
    - product availability
    - shopping requests
    - styles
    - occasion-based shopping

    If the direct search produces no useful products, the agent should
    inspect the real catalog before attempting one fallback search.
    """

    logger.info(
        "[TOOL CALLED] search_inventory | "
        "search_term=%s | category=%s | "
        "max_price=%s | is_featured=%s",
        search_term,
        category,
        max_price,
        is_featured,
    )

    db: Session = SessionLocal()

    try:
        # -------------------------------------------------------------------
        # Load only customer-facing fields.
        #
        # IMPORTANT:
        # Do not load image_embedding/image_embedding_v2 because those
        # vectors are large and unnecessary for conversational search.
        # -------------------------------------------------------------------

        query = (
            db.query(Product)
            .options(
                load_only(
                    Product.id,
                    Product.name,
                    Product.description,
                    Product.price,
                    Product.original_price,
                    Product.image_url,
                    Product.category,
                    Product.rating,
                    Product.reviews,
                    Product.discount_percent,
                    Product.is_featured,
                    Product.stock,
                    Product.fulfillment_type,
                )
            )
        )

        # Only recommend available inventory.
        query = query.filter(
            Product.stock > 0
        )

        # -------------------------------------------------------------------
        # Hard deterministic constraints
        # -------------------------------------------------------------------

        if max_price is not None:
            query = query.filter(
                Product.price <= max_price
            )

        if is_featured is not None:
            query = query.filter(
                Product.is_featured == is_featured
            )

        # -------------------------------------------------------------------
        # Broad lexical candidate retrieval
        # -------------------------------------------------------------------

        candidate_conditions = []

        search_tokens = _search_tokens(
            search_term
        )

        for token in search_tokens:
            pattern = f"%{token}%"

            candidate_conditions.append(
                or_(
                    Product.name.ilike(pattern),
                    Product.category.ilike(pattern),
                    Product.description.ilike(pattern),
                )
            )

        category_tokens = _search_tokens(
            category
        )

        for token in category_tokens:
            pattern = f"%{token}%"

            candidate_conditions.append(
                or_(
                    Product.category.ilike(pattern),
                    Product.name.ilike(pattern),
                    Product.description.ilike(pattern),
                )
            )

        if candidate_conditions:
            query = query.filter(
                or_(
                    *candidate_conditions
                )
            )

        else:
            # No textual criteria:
            # return generally useful products rather than random rows.
            query = query.order_by(
                Product.is_featured.desc(),
                Product.rating.desc(),
                Product.reviews.desc(),
            )

        # Current catalog is small, so a bounded set is inexpensive.
        candidates = (
            query
            .limit(60)
            .all()
        )

        # -------------------------------------------------------------------
        # Relevance ranking
        # -------------------------------------------------------------------

        ranked_products = sorted(
            candidates,
            key=lambda product: (
                _score_product(
                    product,
                    search_term,
                    category,
                ),
                product.rating or 0.0,
                product.reviews or 0,
            ),
            reverse=True,
        )

        selected_products = (
            ranked_products[:5]
        )

        results = [
            _product_to_public_dict(
                product
            )
            for product in selected_products
        ]

        logger.info(
            "[TOOL RESULT] Found %s products: %s",
            len(results),
            [
                {
                    "id": product["id"],
                    "name": product["name"],
                    "category": product["category"],
                }
                for product in results
            ],
        )

        return json.dumps(
            results,
            ensure_ascii=False,
        )

    except Exception:
        logger.exception(
            "[TOOL ERROR] search_inventory failed"
        )

        return "[]"

    finally:
        db.close()


# ===========================================================================
# CATALOG DISCOVERY TOOL
#
# Lets the AI inspect Penguin Store's REAL taxonomy instead of inventing
# generic categories that may not exist in PostgreSQL.
# ===========================================================================

@tool("inspect_catalog")
def inspect_catalog() -> str:
    """
    Inspect currently available Penguin Store categories and representative
    products.

    Use when:
    - direct search returns no products
    - the request is vague
    - the request is occasion-based
    - the database category is uncertain
    - the requested item does not exist
    - alternatives are needed

    After inspecting the catalog, the agent should perform one grounded
    fallback search using terms actually supported by the catalog.
    """

    logger.info(
        "[TOOL CALLED] inspect_catalog"
    )

    db: Session = SessionLocal()

    try:
        rows = (
            db.query(
                Product.category,
                Product.name,
            )
            .filter(
                Product.stock > 0
            )
            .order_by(
                Product.category.asc(),
                Product.name.asc(),
            )
            .all()
        )

        catalog = {}

        for category, name in rows:
            if not category:
                continue

            if category not in catalog:
                catalog[category] = {
                    "count": 0,
                    "examples": [],
                }

            catalog[category]["count"] += 1

            # Keep LLM context small.
            if (
                len(
                    catalog[category]["examples"]
                )
                < 3
            ):
                catalog[category]["examples"].append(
                    name
                )

        categories = [
            {
                "category": category,
                "available_product_count": (
                    data["count"]
                ),
                "example_products": (
                    data["examples"]
                ),
            }
            for category, data
            in catalog.items()
        ]

        result = {
            "instruction": (
                "These are the real categories currently available "
                "in Penguin Store. Use these categories and example "
                "products for grounded fallback searches. Never invent "
                "products or categories."
            ),
            "available_categories": categories,
        }

        logger.info(
            "[TOOL RESULT] inspect_catalog found %s categories",
            len(categories),
        )

        return json.dumps(
            result,
            ensure_ascii=False,
        )

    except Exception:
        logger.exception(
            "[TOOL ERROR] inspect_catalog failed"
        )

        return json.dumps(
            {
                "available_categories": [],
            }
        )

    finally:
        db.close()


# ===========================================================================
# CART TOOL
# ===========================================================================

class AddToCartInput(BaseModel):
    product_id: int = Field(
        ...,
        description=(
            "Exact product ID to add to the cart."
        ),
    )

    quantity: int = Field(
        default=1,
        ge=1,
        description=(
            "Number of units requested."
        ),
    )


@tool(
    "add_to_cart",
    args_schema=AddToCartInput,
)
def add_to_cart(
    product_id: int,
    quantity: int = 1,
) -> str:
    """
    Prepare a customer cart action for an exact product.

    The product must exist and the requested quantity must be available.
    """

    logger.info(
        "[TOOL CALLED] add_to_cart | "
        "product_id=%s | quantity=%s",
        product_id,
        quantity,
    )

    db: Session = SessionLocal()

    try:
        product = (
            db.query(Product)
            .options(
                load_only(
                    Product.id,
                    Product.name,
                    Product.price,
                    Product.image_url,
                    Product.stock,
                )
            )
            .filter(
                Product.id == product_id
            )
            .first()
        )

        if not product:
            return json.dumps(
                {
                    "error": "Product not found.",
                }
            )

        if (
            product.stock is not None
            and product.stock < quantity
        ):
            return json.dumps(
                {
                    "error": (
                        "Requested quantity is not available."
                    ),
                    "available_stock": product.stock,
                }
            )

        result = {
            "action": "add_to_cart",
            "product": {
                "id": product.id,
                "name": product.name,
                "price": product.price,
                "image_url": product.image_url,
            },
            "quantity": quantity,
        }

        logger.info(
            "[TOOL RESULT] Cart action prepared | "
            "product_id=%s | quantity=%s",
            product.id,
            quantity,
        )

        return json.dumps(
            result,
            ensure_ascii=False,
        )

    except Exception:
        logger.exception(
            "[TOOL ERROR] add_to_cart failed"
        )

        return json.dumps(
            {
                "error": (
                    "Unable to prepare cart action."
                ),
            }
        )

    finally:
        db.close()


# ===========================================================================
# ORDER STATUS TOOL
#
# Uses REAL fulfillment data from OrderItem rather than allowing the LLM
# to invent shipment or tracking information.
# ===========================================================================

class OrderStatusInput(BaseModel):
    order_id: Union[str, int] = Field(
        ...,
        description=(
            "Exact Penguin Store order ID supplied by the customer."
        ),
    )


@tool(
    "check_order_status",
    args_schema=OrderStatusInput,
)
def check_order_status(
    order_id: Union[str, int],
) -> str:
    """
    Retrieve the real fulfillment state of a Penguin Store order.

    Order information comes from the orders table.

    Fulfillment state comes from order_items:
    - fulfillment_type
    - dispatch_status
    - tracking_number

    Never invent shipment or tracking information.
    """

    logger.info(
        "[TOOL CALLED] check_order_status | order_id=%s",
        order_id,
    )

    db: Session = SessionLocal()

    try:
        # -------------------------------------------------------------------
        # Validate ID
        # -------------------------------------------------------------------

        clean_id = str(
            order_id
        ).strip()

        if not clean_id.isdigit():
            return json.dumps(
                {
                    "error": (
                        "Order ID must be numeric."
                    ),
                }
            )

        query_id = int(
            clean_id
        )

        # -------------------------------------------------------------------
        # Retrieve order
        # -------------------------------------------------------------------

        order = (
            db.query(Order)
            .filter(
                Order.id == query_id
            )
            .first()
        )

        if not order:
            logger.info(
                "[TOOL RESULT] Order %s not found",
                query_id,
            )

            return json.dumps(
                {
                    "error": (
                        f"Order {query_id} could not be found."
                    ),
                }
            )

        # -------------------------------------------------------------------
        # Retrieve real item-level fulfillment state
        # -------------------------------------------------------------------

        order_items = (
            db.query(OrderItem)
            .filter(
                OrderItem.order_id == query_id
            )
            .order_by(
                OrderItem.id.asc()
            )
            .all()
        )

        # -------------------------------------------------------------------
        # Resolve product names.
        #
        # Query columns directly so vector embedding fields are never loaded.
        # -------------------------------------------------------------------

        product_ids = [
            item.product_id
            for item in order_items
            if item.product_id is not None
        ]

        product_names = {}

        if product_ids:
            product_rows = (
                db.query(
                    Product.id,
                    Product.name,
                )
                .filter(
                    Product.id.in_(
                        product_ids
                    )
                )
                .all()
            )

            product_names = {
                product_id: product_name
                for product_id, product_name
                in product_rows
            }

        # -------------------------------------------------------------------
        # Build customer-safe fulfillment details
        # -------------------------------------------------------------------

        items = []

        for item in order_items:
            items.append(
                {
                    "order_item_id": (
                        item.id
                    ),

                    "product_id": (
                        item.product_id
                    ),

                    "product_name": (
                        product_names.get(
                            item.product_id,
                            "Unknown product",
                        )
                    ),

                    "quantity": (
                        item.quantity
                    ),

                    "unit_price": (
                        item.unit_price
                    ),

                    "fulfillment_type": (
                        item.fulfillment_type
                    ),

                    "dispatch_status": (
                        item.dispatch_status
                        or "PENDING"
                    ),

                    "tracking_number": (
                        item.tracking_number
                    ),
                }
            )

        # -------------------------------------------------------------------
        # Derive order-level status strictly from actual OrderItem statuses.
        # -------------------------------------------------------------------

        statuses = {
            str(
                item.dispatch_status
                or "PENDING"
            ).upper()
            for item in order_items
        }

        if not order_items:
            overall_status = (
                "NO_FULFILLMENT_DATA"
            )

        elif len(statuses) == 1:
            overall_status = next(
                iter(statuses)
            )

        else:
            overall_status = (
                "PARTIALLY_FULFILLED"
            )

        # -------------------------------------------------------------------
        # Only expose tracking numbers that actually exist.
        # -------------------------------------------------------------------

        tracking_numbers = [
            item.tracking_number
            for item in order_items
            if item.tracking_number
        ]

        # -------------------------------------------------------------------
        # Privacy:
        #
        # Do NOT expose customer email/name/address through a simple order-ID
        # lookup because ownership is not yet authenticated by this endpoint.
        # -------------------------------------------------------------------

        result = {
            "action": "order_status",

            "order": {
                "order_id": str(
                    order.id
                ),

                "created_at": (
                    order.created_at.isoformat()
                    if order.created_at
                    else None
                ),

                "total": (
                    order.total_amount
                ),

                "overall_status": (
                    overall_status
                ),

                "tracking_numbers": (
                    tracking_numbers
                ),

                "items": items,
            },
        }

        logger.info(
            "[TOOL RESULT] "
            "Order %s | "
            "status=%s | "
            "items=%s | "
            "tracking_numbers=%s",
            order.id,
            overall_status,
            len(items),
            len(tracking_numbers),
        )

        return json.dumps(
            result,
            ensure_ascii=False,
        )

    except Exception:
        logger.exception(
            "[TOOL ERROR] check_order_status failed"
        )

        return json.dumps(
            {
                "error": (
                    "Unable to retrieve order status."
                ),
            }
        )

    finally:
        db.close()


# ===========================================================================
# STORE KNOWLEDGE TOOL
# ===========================================================================

class KnowledgeBaseSearchInput(BaseModel):
    query: str = Field(
        ...,
        description=(
            "Question about Penguin Store policies, returns, refunds, "
            "warranties, payments, shipping rules, fulfillment, or "
            "other official store information."
        ),
    )


@tool(
    "search_knowledge_base",
    args_schema=KnowledgeBaseSearchInput,
)
def search_knowledge_base(
    query: str,
) -> str:
    """
    Search Penguin Store's official knowledge base.

    This tool should be used for:
    - returns
    - refunds
    - warranties
    - payment information
    - shipping policies
    - fulfillment policies
    - store rules

    The knowledge base is the source of truth.
    """

    logger.info(
        "[TOOL CALLED] search_knowledge_base | query=%s",
        query,
    )

    try:
        context = (
            retrieve_store_knowledge(
                query
            )
        )

        if not context:
            return (
                "No matching information was found "
                "in the Penguin Store knowledge base."
            )

        return context

    except Exception:
        logger.exception(
            "[TOOL ERROR] search_knowledge_base failed"
        )

        return (
            "Unable to retrieve Penguin Store "
            "policy information."
        )