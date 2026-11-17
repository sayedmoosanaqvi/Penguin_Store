import logging
import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi_mail import ConnectionConfig, FastMail, MessageSchema, MessageType
from pydantic import EmailStr

_BACKEND_ENV_PATH = Path(__file__).resolve().parents[1] / ".env"
load_dotenv(_BACKEND_ENV_PATH)
load_dotenv()

logger = logging.getLogger(__name__)

conf = ConnectionConfig(
    MAIL_USERNAME=os.getenv("MAIL_USERNAME") or "",
    MAIL_PASSWORD=os.getenv("MAIL_PASSWORD") or "",
    MAIL_FROM=os.getenv("MAIL_FROM") or "support.penguinstore@gmail.com",
    MAIL_PORT=int(os.getenv("MAIL_PORT", 587)),
    MAIL_SERVER=os.getenv("MAIL_SERVER") or "smtp.gmail.com",
    MAIL_STARTTLS=True,
    MAIL_SSL_TLS=False,
    USE_CREDENTIALS=True,
    VALIDATE_CERTS=True,
)


async def send_order_confirmation(email: EmailStr, order_id: str):
    html_content = f"""
    <h2>Thank you for your purchase!</h2>
    <p>Your order (ID: {order_id}) has been successfully processed.</p>
    <p>The Penguin Store Team</p>
    """

    message = MessageSchema(
        subject="Penguin Store - Order Confirmation",
        recipients=[email],
        body=html_content,
        subtype=MessageType.html,
    )

    try:
        fm = FastMail(conf)
        await fm.send_message(message)
    except Exception as exc:
        logger.warning(
            "Order confirmation email could not be sent for order %s: %s",
            order_id,
            exc,
        )
