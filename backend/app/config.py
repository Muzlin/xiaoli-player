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
