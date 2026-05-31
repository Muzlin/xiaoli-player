from datetime import datetime, timezone
from sqlmodel import SQLModel, Field


def _now() -> datetime:
    return datetime.now(timezone.utc)


class User(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    email: str = Field(index=True, unique=True)
    password_hash: str
    role: str = Field(default="user")  # "user" | "admin"
    created_at: datetime = Field(default_factory=_now)


class MediaFile(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    owner_id: int = Field(foreign_key="user.id", index=True)
    original_name: str
    stored_path: str
    size_bytes: int
    container_format: str
    created_at: datetime = Field(default_factory=_now)
