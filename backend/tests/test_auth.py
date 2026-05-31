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
