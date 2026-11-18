from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, ConfigDict
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.core.database import get_db
from app.core.security import get_current_user, resolve_user_role
from app.models import Notification, User

router = APIRouter(prefix="/api/notifications", tags=["Notifications"])


class NotificationResponse(BaseModel):
    id: int
    title: str
    message: str
    is_read: bool
    notification_type: str
    category: Optional[str] = "SYSTEM"
    action_route: Optional[str] = None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


@router.get("/{email}", response_model=List[NotificationResponse])
def get_user_notifications(
    email: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Fetch all notifications for the authenticated user (or any user as Admin)."""
    clean_email = email.strip().lower()
    if not clean_email:
        return []

    if (
        resolve_user_role(current_user) != "admin"
        and current_user.email.strip().lower() != clean_email
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only view your own notifications.",
        )

    return (
        db.query(Notification)
        .filter(func.lower(Notification.customer_email) == clean_email)
        .order_by(Notification.created_at.desc())
        .all()
    )


@router.put("/read-all")
def mark_all_as_read(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Mark all notifications belonging to the authenticated user as read."""
    clean_email = current_user.email.strip().lower()
    updated = (
        db.query(Notification)
        .filter(
            func.lower(Notification.customer_email) == clean_email,
            Notification.is_read.is_(False),
        )
        .update({"is_read": True}, synchronize_session=False)
    )
    db.commit()
    return {"status": "success", "updated_count": int(updated)}


@router.put("/{notification_id}/read")
def mark_as_read(
    notification_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Mark a specific notification as read after verifying ownership."""
    notification = (
        db.query(Notification)
        .filter(Notification.id == notification_id)
        .first()
    )
    if not notification:
        raise HTTPException(status_code=404, detail="Notification not found")

    if (
        resolve_user_role(current_user) != "admin"
        and (notification.customer_email or "").strip().lower()
        != current_user.email.strip().lower()
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Not authorized to update this notification.",
        )

    notification.is_read = True
    db.commit()
    return {"status": "success", "message": "Notification marked as read"}
