from fastapi import FastAPI

from .admin import router as admin_router
from .auth import router as auth_router
from .db import init_db
from .media import router as media_router

app = FastAPI(title="Media Platform")


@app.on_event("startup")
def on_startup() -> None:
    init_db()


app.include_router(auth_router)
app.include_router(media_router)
app.include_router(admin_router)
