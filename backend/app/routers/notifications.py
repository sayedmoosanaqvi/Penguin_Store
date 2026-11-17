from datetime import datetime
from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Notification, User
from app.security import get_optional_current_user

router = APIRouter(prefix="/api/notifications", tags=["Notifications"])


# Pydantic schema for sending data to the frontend
class NotificationResponse(BaseModel):
    id: int
    title: str
    message: str
    is_read: bool
    notification_type: str
    created_at: datetime

    class Config:
        from_attributes = True


@router.get("/{email}", response_model=List[NotificationResponse])
def get_user_notifications(
    email: str,
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_optional_current_user),
):
    """Fetch all notifications for a specific user, newest first."""
    clean_email = email.strip().lower()
    if not clean_email:
        return []

    if (
        current_user is not None
        and not current_user.is_admin
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


@router.put("/{notification_id}/read")
def mark_as_read(
    notification_id: int,
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_optional_current_user),
):
    """Mark a specific notification as read."""
    notification = (
        db.query(Notification)
        .filter(Notification.id == notification_id)
        .first()
    )
    if not notification:
        raise HTTPException(status_code=404, detail="Notification not found")

    if (
        current_user is not None
        and not current_user.is_admin
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
