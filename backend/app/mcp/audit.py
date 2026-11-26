"""Asynchronous MCP audit logging + live telemetry (Supabase `mcp_audit_logs` + memory)."""

from __future__ import annotations

import json
import logging
import time
from collections import Counter, deque
from datetime import datetime, timezone
from threading import Lock
from typing import Any, Optional

from app.core.supabase_rest import get_supabase_client

logger = logging.getLogger(__name__)

AUDIT_TABLE = "mcp_audit_logs"
_MEM: deque[dict[str, Any]] = deque(maxlen=800)
_LOCK = Lock()
_db_retry_after: float = 0.0


def reset_for_tests() -> None:
    global _db_retry_after
    with _LOCK:
        _MEM.clear()
        _db_retry_after = 0.0


def _db_enabled() -> bool:
    return time.monotonic() >= _db_retry_after


def _backoff_db(seconds: float = 120.0) -> None:
    global _db_retry_after
    _db_retry_after = time.monotonic() + seconds


def log_call(entry: dict[str, Any]) -> None:
    """Persist one MCP invocation. Never raises; safe for BackgroundTasks."""
    row = {
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": str(entry.get("source") or "http")[:24],
        "method": str(entry.get("method") or "")[:128],
        "tool_name": (str(entry["tool_name"])[:128] if entry.get("tool_name") else None),
        "protocol_version": str(entry.get("protocol_version") or "")[:16],
        "principal_type": str(entry.get("principal_type") or "anonymous")[:16],
        "user_id": entry.get("user_id"),
        "key_id": entry.get("key_id"),
        "latency_ms": round(float(entry.get("latency_ms") or 0.0), 2),
        "success": bool(entry.get("success", True)),
        "error_code": entry.get("error_code"),
        "http_status": entry.get("http_status"),
        "client_name": (str(entry["client_name"])[:80] if entry.get("client_name") else None),
    }
    with _LOCK:
        _MEM.appendleft(dict(row))

    if _db_enabled():
        try:
            get_supabase_client().table(AUDIT_TABLE).insert(
                {**row, "metadata_json": json.dumps(entry.get("metadata") or {})[:2000]}
            ).execute()
        except Exception as exc:
            _backoff_db()
            logger.debug("mcp_audit_logs insert skipped (run migration section 19): %s", exc)

    # Feed the existing Admin AI Metrics dashboard + CSV export.
    try:
        from app.core.supabase_rest import is_pg_tcp_reachable
        from app.services.ai_telemetry_service import _insert_metric

        if is_pg_tcp_reachable():
            op = row["tool_name"] or row["method"]
            _insert_metric(
                subsystem="mcp",
                operation=f"{row['method']}:{op}" if row["tool_name"] else op,
                latency_ms=row["latency_ms"],
                success=row["success"],
                tool_calls_count=1 if row["tool_name"] else 0,
                metadata={
                    "source": row["source"],
                    "protocol_version": row["protocol_version"],
                    "principal_type": row["principal_type"],
                },
            )
    except Exception:
        pass


def _load_rows(limit: int = 500) -> list[dict[str, Any]]:
    if _db_enabled():
        try:
            res = (
                get_supabase_client()
                .table(AUDIT_TABLE)
                .select(
                    "created_at,source,method,tool_name,protocol_version,principal_type,"
                    "latency_ms,success,error_code,http_status,client_name"
                )
                .order("created_at", desc=True)
                .limit(limit)
                .execute()
            )
            if res.data:
                return list(res.data)
        except Exception as exc:
            _backoff_db()
            logger.debug("mcp_audit_logs read fallback to memory: %s", exc)
    with _LOCK:
        return list(_MEM)[:limit]


def summarize(include_recent: bool = False, recent_limit: int = 40) -> dict[str, Any]:
    rows = _load_rows()
    total = len(rows)
    latencies = sorted(float(r.get("latency_ms") or 0.0) for r in rows)
    ok = sum(1 for r in rows if r.get("success"))
    tools = Counter(r["tool_name"] for r in rows if r.get("tool_name"))
    versions = Counter(r.get("protocol_version") or "unknown" for r in rows)
    sources = Counter(r.get("source") or "http" for r in rows)
    methods = Counter(r.get("method") or "" for r in rows)

    def _pct(p: float) -> float:
        if not latencies:
            return 0.0
        return round(latencies[min(len(latencies) - 1, int(p * len(latencies)))], 2)

    summary: dict[str, Any] = {
        "total_calls": total,
        "success_rate": round((ok / total) * 100.0, 2) if total else 100.0,
        "avg_latency_ms": round(sum(latencies) / total, 2) if total else 0.0,
        "p95_latency_ms": _pct(0.95),
        "top_tools": [{"tool": t, "calls": c} for t, c in tools.most_common(8)],
        "protocol_versions": dict(versions),
        "sources": dict(sources),
        "methods": [{"method": m, "calls": c} for m, c in methods.most_common(8)],
        "persistence": "supabase" if _db_enabled() else "memory",
        "window": f"last {total} calls",
    }
    summary["metrics"] = {
        "total_invocations": total,
        "success_rate_pct": summary["success_rate"],
        "avg_latency_ms": summary["avg_latency_ms"],
        "active_keys_count": len(set(r["key_id"] for r in rows if r.get("key_id"))),
    }
    summary["recent_invocations"] = rows[:recent_limit]
    if include_recent:
        summary["recent"] = rows[:recent_limit]
    return summary
