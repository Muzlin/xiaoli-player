from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import Session, select

from .auth import require_admin
from .db import get_session
from .models import Device, MediaFile, User

router = APIRouter(prefix="/admin", tags=["admin"])


class AdminMediaResponse(BaseModel):
    id: int
    owner_id: int
    owner_email: str
    original_name: str
    size_bytes: int
    container_format: str


class AdminDeviceResponse(BaseModel):
    id: int
    device_id: str
    user_id: int | None
    owner_email: str
    platform: str
    device_name: str
    app_version: str
    ip: str
    last_seen: datetime
    online: bool


@router.get("/devices", response_model=list[AdminDeviceResponse])
def devices(
    admin: User = Depends(require_admin),
    session: Session = Depends(get_session),
):
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=5)
    out: list[AdminDeviceResponse] = []
    for d in session.exec(select(Device).order_by(Device.last_seen.desc())).all():
        owner = session.get(User, d.user_id) if d.user_id else None
        out.append(
            AdminDeviceResponse(
                id=d.id,
                device_id=d.device_id,
                user_id=d.user_id,
                owner_email=owner.email if owner else "",
                platform=d.platform,
                device_name=d.device_name,
                app_version=d.app_version,
                ip=d.ip,
                last_seen=d.last_seen,
                online=d.last_seen >= cutoff,
            )
        )
    return out


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
