"""Alibaba-Inspired Request for Quotation (RFQ) B2B Endpoints (/api/v1)."""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from threading import Lock
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import (
    get_current_user,
    get_optional_current_user,
    require_role,
    resolve_user_role,
)
from app.core.supabase_rest import (
    fetch_product_by_id_https,
    get_supabase_client,
)
from app.models import User

logger = logging.getLogger(__name__)
router = APIRouter(tags=["B2B RFQ"])

_MEM_LOCK = Lock()
_MEM_RFQS: list[dict[str, Any]] = []
_MEM_SEQ: int = 100


class RFQCreateRequest(BaseModel):
    product_id: int = Field(..., gt=0)
    product_name: Optional[str] = Field(default="", max_length=200)
    customer_email: str = Field(..., min_length=3, max_length=254)
    customer_name: Optional[str] = Field(default="", max_length=150)
    company_name: Optional[str] = Field(default="", max_length=150)
    quantity: int = Field(..., ge=5, le=1_000_000)
    target_unit_price: float = Field(..., gt=0, le=1_000_000)
    customization_notes: Optional[str] = Field(default="", max_length=2000)
    delivery_deadline: Optional[str] = Field(default="", max_length=100)


class RFQAdminUpdateRequest(BaseModel):
    status: str = Field(..., pattern="^(Pending|Quoted|Approved|Rejected)$")
    admin_quote_price: Optional[float] = Field(default=None, gt=0, le=1_000_000)
    admin_reply: Optional[str] = Field(default="", max_length=2000)


def _normalize_rfq(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": int(row.get("id") or 0),
        "user_id": row.get("user_id"),
        "customer_email": str(row.get("customer_email") or ""),
        "customer_name": str(row.get("customer_name") or ""),
        "company_name": str(row.get("company_name") or ""),
        "product_id": int(row.get("product_id") or 0),
        "product_name": str(row.get("product_name") or f"Product #{row.get('product_id')}"),
        "quantity": int(row.get("quantity") or 10),
        "target_unit_price": float(row.get("target_unit_price") or 0.0),
        "customization_notes": str(row.get("customization_notes") or ""),
        "delivery_deadline": str(row.get("delivery_deadline") or ""),
        "status": str(row.get("status") or "Pending"),
        "admin_quote_price": (
            float(row["admin_quote_price"])
            if row.get("admin_quote_price") is not None
            else None
        ),
        "admin_reply": str(row.get("admin_reply") or ""),
        "created_at": str(row.get("created_at") or datetime.now(timezone.utc).isoformat()),
        "updated_at": str(row.get("updated_at") or datetime.now(timezone.utc).isoformat()),
    }


@router.post("/rfq", status_code=status.HTTP_201_CREATED)
def submit_rfq(
    payload: RFQCreateRequest,
    current_user: User | None = Depends(get_optional_current_user),
    db: Session = Depends(get_db),
):
    global _MEM_SEQ
    clean_email = (
        current_user.email.strip().lower()
        if current_user is not None and current_user.email
        else payload.customer_email.strip().lower()
    )
    if "@" not in clean_email:
        raise HTTPException(status_code=422, detail="Enter a valid business email.")

    prod = fetch_product_by_id_https(payload.product_id)
    prod_name = (
        payload.product_name.strip()
        if payload.product_name and payload.product_name.strip()
        else (str(prod.get("name")) if prod else f"Product #{payload.product_id}")
    )

    now_iso = datetime.now(timezone.utc).isoformat()
    insert_data = {
        "user_id": getattr(current_user, "id", None),
        "customer_email": clean_email,
        "customer_name": (payload.customer_name or "").strip(),
        "company_name": (payload.company_name or "").strip(),
        "product_id": payload.product_id,
        "product_name": prod_name,
        "quantity": payload.quantity,
        "target_unit_price": round(float(payload.target_unit_price), 2),
        "customization_notes": (payload.customization_notes or "").strip(),
        "delivery_deadline": (payload.delivery_deadline or "").strip(),
        "status": "Pending",
        "admin_quote_price": None,
        "admin_reply": "",
    }

    try:
        client = get_supabase_client()
        res = client.table("rfq_requests").insert(insert_data).execute()
        rows = res.data or []
        if rows:
            return _normalize_rfq(rows[0])
    except Exception as exc:
        logger.info("RFQ Supabase table fallback to resilient memory store: %s", exc)

    with _MEM_LOCK:
        _MEM_SEQ += 1
        mem_row = {
            **insert_data,
            "id": _MEM_SEQ,
            "created_at": now_iso,
            "updated_at": now_iso,
        }
        _MEM_RFQS.insert(0, mem_row)
        return _normalize_rfq(mem_row)


@router.get("/rfq/my")
def get_my_rfqs(
    email: Optional[str] = Query(default=None, max_length=254),
    current_user: User = Depends(get_current_user),
):
    caller_email = (current_user.email or "").strip().lower()
    is_admin = resolve_user_role(current_user) == "admin"

    if email and email.strip():
        requested_email = email.strip().lower()
        if not is_admin and requested_email != caller_email:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="You can only view your own B2B RFQ quotes.",
            )
        target_email = requested_email
    else:
        target_email = caller_email

    if not target_email:
        return {"count": 0, "items": []}

    items: list[dict[str, Any]] = []
    try:
        client = get_supabase_client()
        res = (
            client.table("rfq_requests")
            .select("*")
            .ilike("customer_email", target_email)
            .order("id", desc=True)
            .execute()
        )
        items.extend(_normalize_rfq(r) for r in (res.data or []) if isinstance(r, dict))
    except Exception:
        pass

    seen_ids = {i["id"] for i in items}
    with _MEM_LOCK:
        for r in _MEM_RFQS:
            if (
                str(r.get("customer_email") or "").lower() == target_email
                and r["id"] not in seen_ids
            ):
                items.append(_normalize_rfq(r))

    return {"count": len(items), "items": items}


@router.get("/admin/rfq")
def list_admin_rfqs(
    status_filter: Optional[str] = Query(default=None),
    admin_user: User = Depends(require_role(["admin"])),
):
    items: list[dict[str, Any]] = []
    try:
        client = get_supabase_client()
        q = client.table("rfq_requests").select("*").order("id", desc=True)
        if status_filter and status_filter.strip() and status_filter != "All":
            q = q.eq("status", status_filter.strip())
        res = q.execute()
        items.extend(_normalize_rfq(r) for r in (res.data or []) if isinstance(r, dict))
    except Exception:
        pass

    seen_ids = {i["id"] for i in items}
    with _MEM_LOCK:
        for r in _MEM_RFQS:
            if r["id"] in seen_ids:
                continue
            if (
                status_filter
                and status_filter.strip()
                and status_filter != "All"
                and r.get("status") != status_filter.strip()
            ):
                continue
            items.append(_normalize_rfq(r))

    return {"count": len(items), "items": items}


@router.patch("/admin/rfq/{rfq_id}")
def update_admin_rfq(
    rfq_id: int,
    payload: RFQAdminUpdateRequest,
    admin_user: User = Depends(require_role(["admin"])),
):
    now_iso = datetime.now(timezone.utc).isoformat()
    updates: dict[str, Any] = {
        "status": payload.status,
        "admin_reply": (payload.admin_reply or "").strip(),
        "updated_at": now_iso,
    }
    if payload.admin_quote_price is not None:
        updates["admin_quote_price"] = round(float(payload.admin_quote_price), 2)

    try:
        client = get_supabase_client()
        res = (
            client.table("rfq_requests")
            .update(updates)
            .eq("id", rfq_id)
            .execute()
        )
        rows = res.data or []
        if rows:
            return _normalize_rfq(rows[0])
    except Exception:
        pass

    with _MEM_LOCK:
        for r in _MEM_RFQS:
            if int(r["id"]) == int(rfq_id):
                r.update(updates)
                return _normalize_rfq(r)

    raise HTTPException(status_code=404, detail=f"RFQ #{rfq_id} not found.")
