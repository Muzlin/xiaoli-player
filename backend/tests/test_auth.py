def test_first_user_is_admin(client):
    r = client.post("/auth/register", json={"email": "a@x.com", "password": "pw"})
    assert r.status_code == 200
    token = r.json()["access_token"]
    me = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["role"] == "admin"


def test_second_user_is_regular(client):
    client.post("/auth/register", json={"email": "a@x.com", "password": "pw"})
    r = client.post("/auth/register", json={"email": "b@x.com", "password": "pw"})
    token = r.json()["access_token"]
    me = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me.json()["role"] == "user"


def test_login_wrong_password_401(client):
    client.post("/auth/register", json={"email": "a@x.com", "password": "pw"})
    r = client.post("/auth/login", json={"email": "a@x.com", "password": "nope"})
    assert r.status_code == 401


def test_me_requires_token(client):
    assert client.get("/auth/me").status_code == 401


def test_non_numeric_sub_yields_401(client):
    from app.security import create_access_token

    token = create_access_token("not-a-number")
    r = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401


def test_admin_email_only_configured_email_is_admin(client, monkeypatch):
    monkeypatch.setenv("APP_ADMIN_EMAIL", "boss@x.com")
    from app.config import get_settings

    get_settings.cache_clear()
    try:
        # First registrant is NOT the configured admin email => plain user.
        first = client.post(
            "/auth/register", json={"email": "early@x.com", "password": "pw"}
        ).json()["access_token"]
        me = client.get("/auth/me", headers={"Authorization": f"Bearer {first}"})
        assert me.json()["role"] == "user"

        # The configured email becomes admin even though it registers later.
        boss = client.post(
            "/auth/register", json={"email": "boss@x.com", "password": "pw"}
        ).json()["access_token"]
        boss_me = client.get("/auth/me", headers={"Authorization": f"Bearer {boss}"})
        assert boss_me.json()["role"] == "admin"
    finally:
        get_settings.cache_clear()
