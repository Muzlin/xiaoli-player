from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlmodel import Session, select

from . import storage
from .auth import get_current_user
from .db import get_session
from .models import MediaFile, User

router = APIRouter(prefix="/media", tags=["media"])

_PUBLIC_FIELDS = {"id", "owner_id", "original_name", "size_bytes", "container_format"}


class MediaResponse(BaseModel):
    id: int
    owner_id: int
    original_name: str
    size_bytes: int
    container_format: str


def _to_response(m: MediaFile) -> MediaResponse:
    return MediaResponse(**m.model_dump(include=_PUBLIC_FIELDS))


def _can_access(user: User, media: MediaFile) -> bool:
    return user.role == "admin" or media.owner_id == user.id


def _get_media_or_error(media_id: int, user: User, session: Session) -> MediaFile:
    media = session.get(MediaFile, media_id)
    if media is None:
        raise HTTPException(status_code=404, detail="Not found")
    if not _can_access(user, media):
        raise HTTPException(status_code=403, detail="Forbidden")
    return media


@router.post("/upload", response_model=MediaResponse)
def upload(
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    stored_path, size, fmt = storage.save_upload(file.file, file.filename)
    media = MediaFile(
        owner_id=user.id,
        original_name=file.filename,
        stored_path=stored_path,
        size_bytes=size,
        container_format=fmt,
    )
    session.add(media)
    session.commit()
    session.refresh(media)
    return _to_response(media)


@router.get("", response_model=list[MediaResponse])
def list_media(
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    stmt = select(MediaFile)
    if user.role != "admin":
        stmt = stmt.where(MediaFile.owner_id == user.id)
    return [_to_response(m) for m in session.exec(stmt).all()]


@router.get("/{media_id}/download")
def download(
    media_id: int,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    media = _get_media_or_error(media_id, user, session)
    return FileResponse(media.stored_path, filename=media.original_name)


@router.get("/{media_id}/stream")
def stream(
    media_id: int,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    media = _get_media_or_error(media_id, user, session)
    # Starlette's FileResponse honors the Range header (206 partial) for seeking.
    return FileResponse(media.stored_path, content_disposition_type="inline")
