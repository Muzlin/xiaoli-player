import io


def _register(client, email):
    return client.post(
        "/auth/register", json={"email": email, "password": "pw"}
    ).json()["access_token"]


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


def test_admin_lists_all_with_owner_email(client, tmp_path, monkeypatch):
    monkeypatch.setenv("APP_UPLOAD_DIR", str(tmp_path))
    from app.config import get_settings

    get_settings.cache_clear()
    admin = _register(client, "admin@x.com")
    user = _register(client, "u@x.com")
    client.post(
        "/media/upload",
        headers=_auth(user),
        files={"file": ("clip.mp4", io.BytesIO(b"data"), "video/mp4")},
    )

    r = client.get("/admin/media", headers=_auth(admin))
    assert r.status_code == 200
    items = r.json()
    assert len(items) == 1
    assert items[0]["owner_email"] == "u@x.com"
    get_settings.cache_clear()


def test_non_admin_forbidden(client):
    _register(client, "admin@x.com")
    user = _register(client, "u@x.com")
    assert client.get("/admin/media", headers=_auth(user)).status_code == 403
