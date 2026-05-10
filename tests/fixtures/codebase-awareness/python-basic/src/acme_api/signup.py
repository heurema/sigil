from acme_shared.validation import normalize_email, validate_email


def create_signup_payload(email: str) -> dict:
    normalized = normalize_email(email)
    return {"email": normalized, "valid": validate_email(normalized)}
