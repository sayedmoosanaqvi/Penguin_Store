from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session, load_only

from app.database import get_db
from app.models import Order, Product, Product3DAsset
from app.security import verify_admin_or_agent

router = APIRouter(prefix="/api/agent", tags=["CTRL-X Agent Tools"])


class AdminCommandRequest(BaseModel):
    command: str = Field(..., min_length=1, max_length=1000)


# ---------------------------------------------------------
# TOOL 1: INVENTORY MONITORING
# The AI or Admin calls this to check what is in stock and what 3D assets exist
# ---------------------------------------------------------
@router.get("/inventory")
async def get_real_inventory(
    caller: str = Depends(verify_admin_or_agent),
    db: Session = Depends(get_db),
):
    products = (
        db.query(Product)
        .options(
            load_only(
                Product.id,
                Product.name,
                Product.stock,
                Product.price,
                Product.category,
                Product.fulfillment_type,
            )
        )
        .order_by(Product.id.asc())
        .all()
    )

    active_3d_rows = (
        db.query(Product3DAsset.product_id)
        .filter(Product3DAsset.is_active.is_(True))
        .distinct()
        .all()
    )
    products_with_3d = {row[0] for row in active_3d_rows}

    agent_inventory = []
    for p in products:
        stock_count = int(p.stock if p.stock is not None else 0)
        agent_inventory.append(
            {
                "id": p.id,
                "name": p.name,
                "category": p.category,
                "stock": stock_count,
                "price": float(p.price),
                "fulfillment_type": p.fulfillment_type or "IN_HOUSE",
                "has_3d_model": p.id in products_with_3d,
                "status": "Low Stock" if stock_count < 5 else "In Stock",
            }
        )

    return {
        "inventory": agent_inventory,
        "total_items": len(agent_inventory),
    }


# ---------------------------------------------------------
# TOOL 2: PRODUCT MANAGEMENT (SEO & Descriptions)
# The AI or Admin calls this to update a product with text it generated
# ---------------------------------------------------------
@router.put("/products/{product_id}/update-seo")
async def agent_update_product_seo(
    product_id: int,
    payload: Dict[str, Any],
    caller: str = Depends(verify_admin_or_agent),
    db: Session = Depends(get_db),
):
    product = (
        db.query(Product)
        .options(
            load_only(
                Product.id,
                Product.name,
                Product.description,
                Product.category,
            )
        )
        .filter(Product.id == product_id)
        .first()
    )

    if not product:
        raise HTTPException(
            status_code=404,
            detail="Product not found in DB",
        )

    if "seo_description" in payload and isinstance(payload["seo_description"], str):
        product.description = payload["seo_description"].strip()[:2000]
    if "tags" in payload and hasattr(product, "tags"):
        setattr(product, "tags", payload["tags"])

    db.commit()
    db.refresh(product)

    return {
        "message": "CTRL-X successfully updated the product.",
        "product_name": product.name,
        "new_description": product.description,
    }


# ---------------------------------------------------------
# TOOL 3: ADMIN CTRL-X STORE MANAGER COMMAND
# Powers the Admin Panel CTRL-X Store Manager console
# ---------------------------------------------------------
@router.post("/admin-command")
async def execute_admin_command(
    request: AdminCommandRequest,
    caller: str = Depends(verify_admin_or_agent),
    db: Session = Depends(get_db),
):
    cmd = request.command.strip()
    cmd_lower = cmd.lower()

    total_products = db.query(Product.id).count()
    low_stock_products = (
        db.query(Product.id, Product.name, Product.stock, Product.category)
        .filter(Product.stock < 10)
        .order_by(Product.stock.asc())
        .limit(10)
        .all()
    )
    in_house_count = (
        db.query(Product.id)
        .filter(Product.fulfillment_type == "IN_HOUSE")
        .count()
    )
    dropship_count = (
        db.query(Product.id)
        .filter(Product.fulfillment_type == "DROPSHIP")
        .count()
    )
    active_3d_count = (
        db.query(Product3DAsset.product_id)
        .filter(Product3DAsset.is_active.is_(True))
        .distinct()
        .count()
    )
    total_orders = db.query(Order.id).count()

    if any(w in cmd_lower for w in ("stock", "inventory", "status", "summary", "report", "stats", "overview")):
        low_stock_str = (
            ", ".join(f"{r.name} ({r.stock} left)" for r in low_stock_products)
            if low_stock_products
            else "None — all products have healthy stock (>= 10 units)."
        )
        return {
            "status": "success",
            "response": (
                f"📊 **CTRL-X Store Diagnostic Report**\n"
                f"• Total Products: {total_products} ({in_house_count} In-House, {dropship_count} Dropship)\n"
                f"• Active 3D Models: {active_3d_count} products\n"
                f"• Total Orders Recorded: {total_orders}\n"
                f"• Low-Stock Alerts (<10 units): {low_stock_str}"
            ),
        }

    # For general queries, delegate to the multi-agent orchestrator
    from app.agent.multi_agent_orchestrator import _invoke_llm_safe, _message_text

    admin_prompt = (
        "You are CTRL-X Store Manager, the executive AI operations console for "
        "Penguin Store administrators.\n"
        f"Live Store Telemetry:\n"
        f"- Total Products: {total_products} ({in_house_count} IN_HOUSE Sargodha warehouse, {dropship_count} DROPSHIP)\n"
        f"- Active 3D GLB Products: {active_3d_count}\n"
        f"- Total Customer Orders: {total_orders}\n"
        f"- Low Stock Products (<10): {len(low_stock_products)}\n\n"
        "Respond concisely and professionally to the administrator's command."
    )
    ai_msg = _invoke_llm_safe(
        [
            {"role": "system", "content": admin_prompt},
            {"role": "user", "content": cmd},
        ]
    )
    text_reply = (
        _message_text(ai_msg)
        if ai_msg is not None
        else (
            f"CTRL-X Store Manager online. Store has {total_products} active products "
            f"({in_house_count} In-House, {dropship_count} Dropship), {active_3d_count} 3D models, "
            f"and {total_orders} orders."
        )
    )
    return {
        "status": "success",
        "response": text_reply,
    }


# ---------------------------------------------------------
# TOOL 4: CTRL-X EXECUTION AUDIT LOGS
# Lets admins and evaluators inspect routed agents, tool calls, and latency
# ---------------------------------------------------------
@router.get("/audit-logs")
async def read_agent_audit_logs(
    limit: int = 50,
    caller: str = Depends(verify_admin_or_agent),
):
    from app.routers.agent_chat import get_audit_logs

    logs = get_audit_logs(limit=limit)
    return {
        "count": len(logs),
        "logs": logs,
    }
