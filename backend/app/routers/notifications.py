from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from pydantic import BaseModel
from datetime import datetime

from app.database import get_db
from app.models import Notification

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
def get_user_notifications(email: str, db: Session = Depends(get_db)):
    """Fetch all notifications for a specific user, newest first."""
    return db.query(Notification).filter(Notification.customer_email == email).order_by(Notification.created_at.desc()).all()

@router.put("/{notification_id}/read")
def mark_as_read(notification_id: int, db: Session = Depends(get_db)):
    """Mark a specific notification as read."""
    notification = db.query(Notification).filter(Notification.id == notification_id).first()
    if not notification:
        raise HTTPException(status_code=404, detail="Notification not found")
    
    notification.is_read = True
    db.commit()
    return {"status": "success", "message": "Notification marked as read"}