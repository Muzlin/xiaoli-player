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
