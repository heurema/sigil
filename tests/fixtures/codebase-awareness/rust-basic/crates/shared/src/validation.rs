pub struct EmailAddress {
    value: String,
}

pub enum ValidationError {
    MissingAtSign,
}

pub trait Validator {
    fn validate(&self, value: &str) -> bool;
}

pub type UserId = String;

pub const DEFAULT_TIMEOUT: u64 = 30;

static CACHE_NAME: &str = "validation";

pub fn validate_email(value: &str) -> bool {
    value.contains("@")
}

pub(crate) fn normalize_email(value: &str) -> String {
    value.trim().to_lowercase()
}

impl EmailAddress {
    pub fn validate(&self) -> bool {
        validate_email(&self.value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_email() {
        assert!(validate_email("a@example.com"));
    }
}
