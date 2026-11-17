
from getpass import getpass

from app.database import SessionLocal
from app.models import User
from app.security import get_password_hash, verify_password

ADMIN_EMAIL = "admin@penguin.com"


def reset_admin_password():
    with SessionLocal() as db:
        admin = db.query(User).filter(
            User.email == ADMIN_EMAIL
        ).first()

        if admin is None:
            print("Error: Administrator account not found.")
            return

        if not admin.is_admin:
            print("Error: This account is not an administrator.")
            return

        print(f"Resetting password for {ADMIN_EMAIL}")

        new_password = getpass("Enter new password: ")
        confirm_password = getpass("Confirm new password: ")

        if new_password != confirm_password:
            print("Error: Passwords do not match.")
            return

        if len(new_password) < 12:
            print("Error: Password must have at least 12 characters.")
            return

        if len(new_password.encode("utf-8")) > 72:
            print("Error: Password exceeds bcrypt's 72-byte limit.")
            return

        admin.hashed_password = get_password_hash(new_password)

        db.commit()

        print("Administrator password successfully updated.")
        print("You can now log in with your new password.")


if __name__ == "__main__":
    reset_admin_password()
