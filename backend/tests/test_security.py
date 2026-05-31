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
