from contextlib import asynccontextmanager

from fastapi import FastAPI

from .admin import router as admin_router
from .auth import router as auth_router
from .config import get_settings
from .db import init_db
from .media import router as media_router

_DEFAULT_SECRET = "dev-secret-change-me"


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    if settings.secret_key == _DEFAULT_SECRET and not settings.dev_mode:
        raise RuntimeError(
            "Refusing to start with the default secret_key while dev_mode is False. "
            "Set APP_SECRET_KEY to a strong secret."
        )
    init_db()
    yield


app = FastAPI(title="小李播放器", lifespan=lifespan)


app.include_router(auth_router)
app.include_router(media_router)
app.include_router(admin_router)
