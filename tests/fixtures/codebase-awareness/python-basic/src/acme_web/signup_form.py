from acme_shared import validation
from acme_shared.validation import validate_email as is_valid_email


class SignupForm:
    def is_valid(self, value: str) -> bool:
        normalized = validation.normalize_email(value)
        return is_valid_email(normalized)
