package users

import (
	"context"

	cfg "example.com/signum-go-basic/internal/auth"
	"example.com/signum-go-basic/pkg/validation"
)

type SignupService struct {
	Auth *cfg.Service
}

func (s SignupService) Signup(ctx context.Context, email string) bool {
	_ = ctx
	_ = cfg.DefaultTimeout
	if s.Auth != nil && !s.Auth.ValidateToken("token") {
		return false
	}
	return validation.ValidateEmail(email)
}
