import io

from app.config import get_settings
from app import storage


def test_save_upload_writes_file_and_returns_metadata(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    get_settings.cache_clear()

    data = b"hello-bytes"
    stored_path, size, fmt = storage.save_upload(io.BytesIO(data), "Song.MP3")

    assert size == len(data)
    assert fmt == "mp3"
    with open(stored_path, "rb") as f:
        assert f.read() == data

    get_settings.cache_clear()
