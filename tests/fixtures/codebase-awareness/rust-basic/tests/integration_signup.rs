use api::signup::{create_signup, SignupRequest};

#[tokio::test]
async fn accepts_signup_email() {
    let request = SignupRequest {
        email: "a@example.com".to_string(),
    };

    assert!(create_signup(request).await);
}
