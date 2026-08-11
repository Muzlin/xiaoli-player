from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlmodel import Session, select

from .db import get_session
from .models import Device

router = APIRouter(prefix="", tags=["devices"])


class HeartbeatRequest(BaseModel):
    device_id: str
    platform: str = ""
    device_name: str = ""
    app_version: str = ""


def _now() -> datetime:
    return datetime.now(timezone.utc)


@router.post("/heartbeat")
def heartbeat(
    req: HeartbeatRequest,
    request: Request,
    session: Session = Depends(get_session),
):
    if not req.device_id:
        return {"ok": False, "error": "device_id required"}
    ip = request.client.host if request.client else ""
    d = session.exec(select(Device).where(Device.device_id == req.device_id)).first()
    if d:
        d.last_seen = _now()
        d.platform = req.platform
        d.device_name = req.device_name
        d.app_version = req.app_version
        d.ip = ip
    else:
        d = Device(
            device_id=req.device_id,
            platform=req.platform,
            device_name=req.device_name,
            app_version=req.app_version,
            ip=ip,
        )
        session.add(d)
    session.commit()
    return {"ok": True, "device_id": req.device_id}
