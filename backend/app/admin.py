from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import Session, select

from .auth import require_admin
from .db import get_session
from .models import MediaFile, User

router = APIRouter(prefix="/admin", tags=["admin"])


class AdminMediaResponse(BaseModel):
    id: int
    owner_id: int
    owner_email: str
    original_name: str
    size_bytes: int
    container_format: str


@router.get("/media", response_model=list[AdminMediaResponse])
def all_media(
    admin: User = Depends(require_admin),
    session: Session = Depends(get_session),
):
    out: list[AdminMediaResponse] = []
    for m in session.exec(select(MediaFile)).all():
        owner = session.get(User, m.owner_id)
        out.append(
            AdminMediaResponse(
                id=m.id,
                owner_id=m.owner_id,
                owner_email=owner.email if owner else "",
                original_name=m.original_name,
                size_bytes=m.size_bytes,
                container_format=m.container_format,
            )
        )
    return out
