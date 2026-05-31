import io


def _register(client, email):
    r = client.post("/auth/register", json={"email": email, "password": "pw"})
    return r.json()["access_token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def _upload(client, token, name=b"clip.mp4"):
    return client.post(
        "/media/upload",
        headers=_auth(token),
        files={"file": ("clip.mp4", io.BytesIO(b"data"), "video/mp4")},
    )


def test_upload_returns_metadata(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    from app.config import get_settings

    get_settings.cache_clear()
    token = _register(client, "a@x.com")
    r = _upload(client, token)
    assert r.status_code == 200
    body = r.json()
    assert body["original_name"] == "clip.mp4"
    assert body["container_format"] == "mp4"
    get_settings.cache_clear()


def test_user_lists_only_own_files(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    from app.config import get_settings

    get_settings.cache_clear()
    admin = _register(client, "admin@x.com")  # first user = admin
    user = _register(client, "u@x.com")
    _upload(client, admin)
    _upload(client, user)

    user_list = client.get("/media", headers=_auth(user)).json()
    assert len(user_list) == 1

    admin_list = client.get("/media", headers=_auth(admin)).json()
    assert len(admin_list) == 2  # admin sees all
    get_settings.cache_clear()


def test_other_user_cannot_download_403(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    from app.config import get_settings

    get_settings.cache_clear()
    admin = _register(client, "admin@x.com")
    user = _register(client, "u@x.com")
    other = _register(client, "o@x.com")
    media_id = _upload(client, user).json()["id"]

    assert client.get(f"/media/{media_id}/download", headers=_auth(other)).status_code == 403
    assert client.get(f"/media/{media_id}/download", headers=_auth(user)).status_code == 200
    assert client.get(f"/media/{media_id}/download", headers=_auth(admin)).status_code == 200
    get_settings.cache_clear()


def test_stream_supports_range(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    from app.config import get_settings

    get_settings.cache_clear()
    token = _register(client, "a@x.com")
    media_id = _upload(client, token).json()["id"]

    r = client.get(
        f"/media/{media_id}/stream",
        headers={**_auth(token), "Range": "bytes=0-1"},
    )
    assert r.status_code == 206
    assert r.headers["content-range"].startswith("bytes 0-1/")
    get_settings.cache_clear()


def test_missing_media_404(client):
    token = _register(client, "a@x.com")
    assert client.get("/media/999/download", headers=_auth(token)).status_code == 404


def test_upload_too_large_413(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    monkeypatch.setenv("APP_MAX_UPLOAD_BYTES", "4")
    from app.config import get_settings

    get_settings.cache_clear()
    token = _register(client, "a@x.com")
    r = client.post(
        "/media/upload",
        headers=_auth(token),
        files={"file": ("clip.mp4", io.BytesIO(b"too-many-bytes"), "video/mp4")},
    )
    assert r.status_code == 413
    get_settings.cache_clear()


def test_other_user_cannot_stream_403(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    from app.config import get_settings

    get_settings.cache_clear()
    _register(client, "admin@x.com")  # first user = admin
    user = _register(client, "u@x.com")
    other = _register(client, "o@x.com")  # non-owner, non-admin
    media_id = _upload(client, user).json()["id"]

    assert client.get(f"/media/{media_id}/stream", headers=_auth(other)).status_code == 403
    assert client.get(f"/media/{media_id}/stream", headers=_auth(user)).status_code == 200
    get_settings.cache_clear()


def test_expired_token_yields_401(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    monkeypatch.setenv("APP_ACCESS_TOKEN_EXPIRE_MINUTES", "-1")  # already expired
    from app.config import get_settings

    get_settings.cache_clear()
    from app.security import create_access_token

    # Mint a token that expired in the past via the negative-expiry setting.
    expired = create_access_token("1")

    r = client.get("/auth/me", headers={"Authorization": f"Bearer {expired}"})
    assert r.status_code == 401
    # Clear the cache AFTER the request so the expired setting does not leak
    # into later tests (the request itself repopulates the lru_cache).
    get_settings.cache_clear()
