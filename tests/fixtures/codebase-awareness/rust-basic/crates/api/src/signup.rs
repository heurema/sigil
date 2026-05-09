use shared::validation::validate_email;

pub struct SignupRequest {
    pub email: String,
}

pub async fn create_signup(request: SignupRequest) -> bool {
    validate_email(&request.email)
}
