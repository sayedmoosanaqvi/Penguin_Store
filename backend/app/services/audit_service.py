"""Audit logging service persisting CTRL-X runs + keeping a fast in-memory buffer."""

from __future__ import annotations

import json
import logging
from collections import deque
from threading import Lock
from typing import Any

from app.core.database import SessionLocal
from app.models import CtrlXAuditLog

logger = logging.getLogger(__name__)

_MEMORY_AUDIT_LOGS: deque[dict[str, Any]] = deque(maxlen=200)
_AUDIT_LOCK = Lock()


def record_ctrlx_audit(entry: dict[str, Any]) -> None:
    with _AUDIT_LOCK:
        _MEMORY_AUDIT_LOGS.appendleft(entry)

    # Persist asynchronously/best-effort to Supabase PostgreSQL without failing caller
    db = SessionLocal()
    try:
        db.add(
            CtrlXAuditLog(
                thread_id=str(entry.get("thread_id", ""))[:200],
                user_email=entry.get("user_email"),
                user_input=str(entry.get("user_input", ""))[:500],
                routed_agent=str(entry.get("routed_agent", "CTRL-X"))[:80],
                tools_called=json.dumps(entry.get("tools_called") or []),
                data_type=str(entry.get("data_type", "text"))[:50],
                latency_ms=float(entry.get("latency_ms", 0.0)),
                status=str(entry.get("status", "success"))[:30],
            )
        )
        db.commit()
    except Exception:
        db.rollback()
        logger.debug("Audit DB write skipped or failed gracefully.", exc_info=True)
    finally:
        db.close()


def fetch_ctrlx_audit_logs(limit: int = 50) -> list[dict[str, Any]]:
    bounded = max(1, min(limit, 200))
    db = SessionLocal()
    try:
        rows = (
            db.query(CtrlXAuditLog)
            .order_by(CtrlXAuditLog.created_at.desc())
            .limit(bounded)
            .all()
        )
        if rows:
            return [
                {
                    "id": r.id,
                    "timestamp": r.created_at.isoformat() if r.created_at else None,
                    "thread_id": r.thread_id,
                    "user_email": r.user_email,
                    "user_input": r.user_input,
                    "routed_agent": r.routed_agent,
                    "tools_called": json.loads(r.tools_called or "[]"),
                    "data_type": r.data_type,
                    "latency_ms": r.latency_ms,
                    "status": r.status,
                }
                for r in rows
            ]
    except Exception:
        logger.debug("Audit DB read falling back to in-memory buffer.", exc_info=True)
    finally:
        db.close()

    with _AUDIT_LOCK:
        return list(_MEMORY_AUDIT_LOGS)[:bounded]
