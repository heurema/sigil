from acme_api.signup import create_signup_payload


def test_create_signup_payload_reuses_validation() -> None:
    payload = create_signup_payload(" USER@EXAMPLE.COM ")
    assert payload == {"email": "user@example.com", "valid": True}
