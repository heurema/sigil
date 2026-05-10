import pytest

from acme_shared.validation import EmailValidator, normalize_email, validate_email


@pytest.fixture
def validator() -> EmailValidator:
    return EmailValidator()


def test_validate_email(validator: EmailValidator) -> None:
    assert validator.validate("user@example.com")


def test_normalize_email() -> None:
    assert normalize_email(" USER@EXAMPLE.COM ") == "user@example.com"


def test_validate_email_rejects_missing_at() -> None:
    assert validate_email("missing") is False
