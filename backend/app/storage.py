import uuid
from pathlib import Path
from typing import BinaryIO

from .config import get_settings

_CHUNK = 1024 * 1024


def _ext(filename: str) -> str:
    return Path(filename).suffix.lower().lstrip(".")


def save_upload(file_obj: BinaryIO, original_name: str) -> tuple[str, int, str]:
    """Stream file_obj to disk. Returns (stored_path, size_bytes, container_format)."""
    settings = get_settings()
    upload_dir = Path(settings.upload_dir)
    upload_dir.mkdir(parents=True, exist_ok=True)

    fmt = _ext(original_name)
    stored_name = f"{uuid.uuid4().hex}.{fmt}" if fmt else uuid.uuid4().hex
    stored_path = upload_dir / stored_name

    size = 0
    with open(stored_path, "wb") as out:
        while True:
            chunk = file_obj.read(_CHUNK)
            if not chunk:
                break
            size += len(chunk)
            out.write(chunk)

    return str(stored_path), size, fmt
