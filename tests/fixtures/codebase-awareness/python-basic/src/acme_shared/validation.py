from dataclasses import dataclass

from pydantic import BaseModel

EMAIL_SUFFIX = "@example.com"
DEFAULT_TIMEOUT = 30


@dataclass
class EmailValidator:
    suffix: str = EMAIL_SUFFIX

    def validate(self, value: str) -> bool:
        return validate_email(value)

    @staticmethod
    def normalize(value: str) -> str:
        return normalize_email(value)

    def _format_for_log(self, value: str) -> str:
        return _private_format_email(value)


class SignupPayload(BaseModel):
    email: str


async def fetch_user(email: str) -> dict:
    return {"email": normalize_email(email)}


def validate_email(value: str) -> bool:
    return "@" in value


def normalize_email(value: str) -> str:
    return value.strip().lower()


def _private_format_email(value: str) -> str:
    return value.strip()
