# Backend Platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A FastAPI backend providing account login, media upload, role-based file listing, authenticated streaming/download, and an admin view of all uploads.

**Architecture:** A single FastAPI app split into focused modules (config, db, models, security, auth, storage, media, admin). Auth uses JWT bearer tokens. Files are stored on the local filesystem with metadata in a SQL database. Permission rule: a user sees only their own files; an admin sees everyone's. Streaming uses Starlette's `FileResponse`, which serves HTTP Range requests for seeking.

**Tech Stack:** Python 3.11+, FastAPI, SQLModel, PyJWT, passlib (pbkdf2_sha256), pytest, httpx (TestClient).

---

## File Structure

```
backend/
  app/
    __init__.py
    config.py        # Settings (secret, upload dir, limits, admin email)
    db.py            # engine + get_session dependency + init_db
    models.py        # User, MediaFile (SQLModel tables)
    security.py      # password hashing + JWT encode/decode
    auth.py          # /auth router + get_current_user / require_admin deps
    storage.py       # save uploaded file to disk
    media.py         # /media router: upload, list, stream, download
    admin.py         # /admin router: list all files
    main.py          # FastAPI app wiring
  tests/
    __init__.py
    conftest.py      # in-memory DB + temp upload dir + TestClient fixtures
    test_security.py
    test_auth.py
    test_media.py
    test_admin.py
  pyproject.toml
```

---

### Task 1: Project setup

**Files:**
- Create: `backend/pyproject.toml`
- Create: `backend/app/__init__.py` (empty)
- Create: `backend/tests/__init__.py` (empty)
- Create: `backend/tests/test_smoke.py`

- [ ] **Step 1: Write pyproject.toml**

```toml
[project]
name = "media-platform-backend"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.110",
    "uvicorn[standard]>=0.29",
    "sqlmodel>=0.0.16",
    "pyjwt>=2.8",
    "passlib>=1.7.4",
    "pydantic[email]>=2.6",
    "python-multipart>=0.0.9",
]

[project.optional-dependencies]
dev = ["pytest>=8.0", "httpx>=0.27"]

[tool.pytest.ini_options]
pythonpath = ["."]
testpaths = ["tests"]
```

- [ ] **Step 2: Create empty package files**

Create `backend/app/__init__.py` and `backend/tests/__init__.py` as empty files.

- [ ] **Step 3: Write a smoke test**

`backend/tests/test_smoke.py`:

```python
def test_python_works():
    assert 1 + 1 == 2
```

- [ ] **Step 4: Install deps and run the smoke test**

Run (from `backend/`): `pip install -e ".[dev]" && pytest tests/test_smoke.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/pyproject.toml backend/app/__init__.py backend/tests/__init__.py backend/tests/test_smoke.py
git commit -m "chore(backend): project skeleton and deps"
```

---

### Task 2: Config

**Files:**
- Create: `backend/app/config.py`

- [ ] **Step 1: Write config**

`backend/app/config.py`:

```python
from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_")

    secret_key: str = "dev-secret-change-me"
    access_token_expire_minutes: int = 60 * 24
    upload_dir: str = "uploads"
    max_upload_bytes: int = 2 * 1024 * 1024 * 1024  # 2 GiB
    admin_email: str | None = None  # if set, this email is admin; else first user is admin
    database_url: str = "sqlite:///./app.db"


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

Add `pydantic-settings>=2.0` to `dependencies` in `pyproject.toml`.

- [ ] **Step 2: Verify it imports**

Run (from `backend/`): `python -c "from app.config import get_settings; print(get_settings().upload_dir)"`
Expected: prints `uploads`.

- [ ] **Step 3: Commit**

```bash
git add backend/app/config.py backend/pyproject.toml
git commit -m "feat(backend): settings module"
```

---

### Task 3: Database and models

**Files:**
- Create: `backend/app/models.py`
- Create: `backend/app/db.py`

- [ ] **Step 1: Write models**

`backend/app/models.py`:

```python
from datetime import datetime, timezone
from sqlmodel import SQLModel, Field


def _now() -> datetime:
    return datetime.now(timezone.utc)


class User(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    email: str = Field(index=True, unique=True)
    password_hash: str
    role: str = Field(default="user")  # "user" | "admin"
    created_at: datetime = Field(default_factory=_now)


class MediaFile(SQLModel, table=True):
    id: int | None = Field(default=None, primary_key=True)
    owner_id: int = Field(foreign_key="user.id", index=True)
    original_name: str
    stored_path: str
    size_bytes: int
    container_format: str
    created_at: datetime = Field(default_factory=_now)
```

- [ ] **Step 2: Write db module**

`backend/app/db.py`:

```python
from sqlmodel import SQLModel, Session, create_engine
from .config import get_settings

_settings = get_settings()
engine = create_engine(
    _settings.database_url,
    connect_args={"check_same_thread": False},
)


def init_db() -> None:
    SQLModel.metadata.create_all(engine)


def get_session():
    with Session(engine) as session:
        yield session
```

- [ ] **Step 3: Verify import + table creation against in-memory DB**

Run (from `backend/`):
```bash
python -c "
from sqlmodel import SQLModel, create_engine
import app.models  # noqa
e = create_engine('sqlite://')
SQLModel.metadata.create_all(e)
print(sorted(SQLModel.metadata.tables.keys()))
"
```
Expected: prints `['mediafile', 'user']`.

- [ ] **Step 4: Commit**

```bash
git add backend/app/models.py backend/app/db.py
git commit -m "feat(backend): db engine and models"
```

---

### Task 4: Security (password hashing + JWT)

**Files:**
- Create: `backend/app/security.py`
- Test: `backend/tests/test_security.py`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_security.py`:

```python
from app.security import (
    hash_password,
    verify_password,
    create_access_token,
    decode_access_token,
)


def test_hash_and_verify_password():
    h = hash_password("s3cret")
    assert h != "s3cret"
    assert verify_password("s3cret", h) is True
    assert verify_password("wrong", h) is False


def test_token_round_trip():
    token = create_access_token("42")
    assert decode_access_token(token) == "42"


def test_decode_invalid_token_returns_none():
    assert decode_access_token("not-a-token") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_security.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.security'`.

- [ ] **Step 3: Write implementation**

`backend/app/security.py`:

```python
from datetime import datetime, timedelta, timezone

import jwt
from passlib.context import CryptContext

from .config import get_settings

_pwd = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")
_ALGORITHM = "HS256"


def hash_password(password: str) -> str:
    return _pwd.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    return _pwd.verify(password, password_hash)


def create_access_token(subject: str) -> str:
    settings = get_settings()
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.access_token_expire_minutes
    )
    payload = {"sub": subject, "exp": expire}
    return jwt.encode(payload, settings.secret_key, algorithm=_ALGORITHM)


def decode_access_token(token: str) -> str | None:
    settings = get_settings()
    try:
        payload = jwt.decode(token, settings.secret_key, algorithms=[_ALGORITHM])
    except jwt.PyJWTError:
        return None
    return payload.get("sub")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_security.py -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/app/security.py backend/tests/test_security.py
git commit -m "feat(backend): password hashing and JWT helpers"
```

---

### Task 5: Auth router + current-user dependencies

**Files:**
- Create: `backend/app/auth.py`
- Create: `backend/tests/conftest.py`
- Test: `backend/tests/test_auth.py`

- [ ] **Step 1: Write the test fixtures**

`backend/tests/conftest.py`:

```python
import pytest
from fastapi.testclient import TestClient
from sqlmodel import SQLModel, Session, create_engine
from sqlmodel.pool import StaticPool

import app.models  # noqa: F401  (register tables)
from app.db import get_session
from app.main import app


@pytest.fixture
def session():
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    SQLModel.metadata.create_all(engine)
    with Session(engine) as s:
        yield s


@pytest.fixture
def client(session):
    def _get_session_override():
        yield session

    app.dependency_overrides[get_session] = _get_session_override
    yield TestClient(app)
    app.dependency_overrides.clear()
```

- [ ] **Step 2: Write the failing test**

`backend/tests/test_auth.py`:

```python
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pytest tests/test_auth.py -v`
Expected: FAIL (no `app.main` / `app.auth` yet).

- [ ] **Step 4: Write the auth module**

`backend/app/auth.py`:

```python
from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordBearer
from pydantic import BaseModel, EmailStr
from sqlmodel import Session, select

from .config import get_settings
from .db import get_session
from .models import User
from .security import (
    create_access_token,
    decode_access_token,
    hash_password,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="auth/login", auto_error=True)


class CredentialsRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class UserResponse(BaseModel):
    id: int
    email: str
    role: str


def _assign_role(session: Session, email: str) -> str:
    settings = get_settings()
    if settings.admin_email and email == settings.admin_email:
        return "admin"
    first_user = session.exec(select(User)).first()
    return "admin" if first_user is None else "user"


@router.post("/register", response_model=TokenResponse)
def register(req: CredentialsRequest, session: Session = Depends(get_session)):
    existing = session.exec(select(User).where(User.email == req.email)).first()
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")
    role = _assign_role(session, req.email)
    user = User(email=req.email, password_hash=hash_password(req.password), role=role)
    session.add(user)
    session.commit()
    session.refresh(user)
    return TokenResponse(access_token=create_access_token(str(user.id)))


@router.post("/login", response_model=TokenResponse)
def login(req: CredentialsRequest, session: Session = Depends(get_session)):
    user = session.exec(select(User).where(User.email == req.email)).first()
    if not user or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    return TokenResponse(access_token=create_access_token(str(user.id)))


def get_current_user(
    token: str = Depends(oauth2_scheme),
    session: Session = Depends(get_session),
) -> User:
    subject = decode_access_token(token)
    if subject is None:
        raise HTTPException(status_code=401, detail="Invalid token")
    user = session.get(User, int(subject))
    if user is None:
        raise HTTPException(status_code=401, detail="User not found")
    return user


def require_admin(user: User = Depends(get_current_user)) -> User:
    if user.role != "admin":
        raise HTTPException(status_code=403, detail="Admin only")
    return user


@router.get("/me", response_model=UserResponse)
def me(user: User = Depends(get_current_user)):
    return UserResponse(id=user.id, email=user.email, role=user.role)
```

- [ ] **Step 5: Write minimal main.py so the app imports**

`backend/app/main.py`:

```python
from fastapi import FastAPI

from .auth import router as auth_router
from .db import init_db

app = FastAPI(title="Media Platform")


@app.on_event("startup")
def on_startup() -> None:
    init_db()


app.include_router(auth_router)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `pytest tests/test_auth.py -v`
Expected: PASS (4 tests).

- [ ] **Step 7: Commit**

```bash
git add backend/app/auth.py backend/app/main.py backend/tests/conftest.py backend/tests/test_auth.py
git commit -m "feat(backend): auth register/login/me with role assignment"
```

---

### Task 6: Storage module

**Files:**
- Create: `backend/app/storage.py`
- Test: add `test_storage.py`

**Note:** Tests set `APP_UPLOAD_DIR` to a temp dir via monkeypatch + `get_settings.cache_clear()`.

- [ ] **Step 1: Write the failing test**

`backend/tests/test_storage.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_storage.py -v`
Expected: FAIL (`No module named 'app.storage'`).

- [ ] **Step 3: Write implementation**

`backend/app/storage.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_storage.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add backend/app/storage.py backend/tests/test_storage.py
git commit -m "feat(backend): filesystem storage for uploads"
```

---

### Task 7: Media router — upload + list (role-based)

**Files:**
- Create: `backend/app/media.py`
- Modify: `backend/app/main.py` (include media router)
- Test: `backend/tests/test_media.py`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_media.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_media.py -v`
Expected: FAIL (no `/media` routes).

- [ ] **Step 3: Write the media router**

`backend/app/media.py`:

```python
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
```

- [ ] **Step 4: Wire the router into main.py**

In `backend/app/main.py`, add after the auth import/include:

```python
from .media import router as media_router
app.include_router(media_router)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/test_media.py -v`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/media.py backend/app/main.py backend/tests/test_media.py
git commit -m "feat(backend): media upload and role-based listing"
```

---

### Task 8: Media stream + download permissions

**Files:**
- Modify: `backend/tests/test_media.py` (add cases)

The stream/download routes already exist (Task 7). This task locks their behavior with tests.

- [ ] **Step 1: Add the failing tests**

Append to `backend/tests/test_media.py`:

```python
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
```

- [ ] **Step 2: Run tests**

Run: `pytest tests/test_media.py -v`
Expected: PASS for all. If `test_stream_supports_range` fails because the installed Starlette does not serve Range for `FileResponse`, replace the `stream` body in `app/media.py` with the explicit Range implementation below, then re-run:

```python
import os
from fastapi import Request
from fastapi.responses import Response


def _parse_range(range_header: str, file_size: int) -> tuple[int, int]:
    units, _, rng = range_header.partition("=")
    start_s, _, end_s = rng.partition("-")
    start = int(start_s) if start_s else 0
    end = int(end_s) if end_s else file_size - 1
    end = min(end, file_size - 1)
    return start, end


@router.get("/{media_id}/stream")
def stream(
    media_id: int,
    request: Request,
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    media = _get_media_or_error(media_id, user, session)
    file_size = os.path.getsize(media.stored_path)
    range_header = request.headers.get("range")
    if range_header is None:
        return FileResponse(media.stored_path, content_disposition_type="inline")
    start, end = _parse_range(range_header, file_size)
    with open(media.stored_path, "rb") as f:
        f.seek(start)
        chunk = f.read(end - start + 1)
    headers = {
        "Content-Range": f"bytes {start}-{end}/{file_size}",
        "Accept-Ranges": "bytes",
        "Content-Length": str(len(chunk)),
    }
    return Response(chunk, status_code=206, headers=headers, media_type="application/octet-stream")
```

(Note `request: Request` is added to the signature in the fallback version.)

- [ ] **Step 3: Commit**

```bash
git add backend/app/media.py backend/tests/test_media.py
git commit -m "test(backend): stream/download permission and range behavior"
```

---

### Task 9: Admin router — list all files with owner

**Files:**
- Create: `backend/app/admin.py`
- Modify: `backend/app/main.py` (include admin router)
- Test: `backend/tests/test_admin.py`

- [ ] **Step 1: Write the failing test**

`backend/tests/test_admin.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_admin.py -v`
Expected: FAIL (no `/admin` routes).

- [ ] **Step 3: Write the admin router**

`backend/app/admin.py`:

```python
from fastapi import APIRouter, Depends
from pydantic import BaseModel
from sqlmodel import Session, select

from .auth import require_admin
from .db import get_session
from .models import MediaFile, User

router = APIRouter(prefix="/admin", tags=["admin"])


class AdminMediaResponse(BaseModel):
    id: int
    owner_id: int
    owner_email: str
    original_name: str
    size_bytes: int
    container_format: str


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
```

- [ ] **Step 4: Wire the router into main.py**

In `backend/app/main.py`, add:

```python
from .admin import router as admin_router
app.include_router(admin_router)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/test_admin.py -v`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/app/admin.py backend/app/main.py backend/tests/test_admin.py
git commit -m "feat(backend): admin endpoint listing all uploads"
```

---

### Task 10: Enforce upload size limit (413)

**Files:**
- Modify: `backend/app/storage.py` (raise on overflow)
- Modify: `backend/app/media.py` (map overflow to HTTP 413)
- Test: add a case to `backend/tests/test_media.py`

- [ ] **Step 1: Add the failing test**

Append to `backend/tests/test_media.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_media.py::test_upload_too_large_413 -v`
Expected: FAIL (upload returns 200, not 413).

- [ ] **Step 3: Raise in storage on overflow**

In `backend/app/storage.py`, add an exception type and enforce the cap inside `save_upload`:

```python
class UploadTooLarge(Exception):
    pass
```

Then in `save_upload`, after `settings = get_settings()` and inside the write loop, track and check the size, deleting the partial file on overflow:

```python
    max_bytes = settings.max_upload_bytes
    size = 0
    with open(stored_path, "wb") as out:
        while True:
            chunk = file_obj.read(_CHUNK)
            if not chunk:
                break
            size += len(chunk)
            if size > max_bytes:
                out.close()
                stored_path.unlink(missing_ok=True)
                raise UploadTooLarge()
            out.write(chunk)
```

(Replace the existing size/write loop with this version.)

- [ ] **Step 4: Map the exception to 413 in the upload route**

In `backend/app/media.py`, update the `upload` handler to catch it:

```python
from .storage import UploadTooLarge


@router.post("/upload", response_model=MediaResponse)
def upload(
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    session: Session = Depends(get_session),
):
    try:
        stored_path, size, fmt = storage.save_upload(file.file, file.filename)
    except UploadTooLarge:
        raise HTTPException(status_code=413, detail="File too large")
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/test_media.py -v`
Expected: PASS (all media tests, including the new 413 case).

- [ ] **Step 6: Commit**

```bash
git add backend/app/storage.py backend/app/media.py backend/tests/test_media.py
git commit -m "feat(backend): enforce max upload size (413)"
```

---

### Task 11: Full suite + run server manually

**Files:** none (verification task)

- [ ] **Step 1: Run the entire suite**

Run (from `backend/`): `pytest -v`
Expected: ALL tests pass.

- [ ] **Step 2: Start the server and smoke-test by hand**

Run: `uvicorn app.main:app --reload`
Then in another terminal:
```bash
curl -s -X POST localhost:8000/auth/register -H 'content-type: application/json' -d '{"email":"admin@x.com","password":"pw"}'
```
Expected: JSON with `access_token`. Visit `http://localhost:8000/docs` to confirm all routes (`/auth/*`, `/media/*`, `/admin/media`) are present.

- [ ] **Step 3: Commit any fixups**

```bash
git add -A
git commit -m "chore(backend): full suite green" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:**
- Login required / accounts → Task 5 (register/login/me, JWT). ✓
- Upload → Task 7. ✓
- Role-based listing (user sees own, admin sees all) → Tasks 7, 9. ✓
- Streaming all formats (Range/seek) → Tasks 7, 8 (engine-agnostic; backend just serves bytes). ✓
- Admin sees all uploads and downloads → Tasks 8 (download permission incl. admin), 9 (admin list). ✓
- Error handling (401/403/404/Range) → Tasks 5, 8. ✓
- Admin role assignment (first user or configured email) → Task 5 `_assign_role`. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `get_current_user`/`require_admin` used consistently across `media.py` and `admin.py`; `MediaResponse` fields match `_PUBLIC_FIELDS`; `_assign_role`, `_can_access`, `_get_media_or_error` defined where used. ✓

- Upload size limit (413) → Task 10. ✓

Every spec requirement maps to a task.
