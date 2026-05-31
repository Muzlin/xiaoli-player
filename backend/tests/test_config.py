import pytest
from fastapi.testclient import TestClient

from app.config import Settings


def test_startup_guard_raises_on_default_secret_in_prod(monkeypatch):
    """The lifespan startup guard must refuse the default secret when dev_mode is False."""
    from app import main

    # Default secret + dev_mode disabled => must raise at startup.
    settings = Settings(dev_mode=False)
    assert settings.secret_key == "dev-secret-change-me"
    monkeypatch.setattr(main, "get_settings", lambda: settings)

    # Entering the TestClient context triggers the FastAPI lifespan startup.
    with pytest.raises(RuntimeError):
        with TestClient(main.app):
            pass
