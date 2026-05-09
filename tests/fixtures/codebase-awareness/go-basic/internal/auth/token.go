package auth

import (
	"errors"
	"strings"
	"time"
)

const DefaultTimeout = 30 * time.Second

var ErrInvalidToken = errors.New("invalid token")

type User struct {
	Email string
	Role  Role
}

type Store interface {
	Save(User) error
}

type Role string

type Service struct{}

type Repository struct{}

func ValidateToken(value string) bool {
	return parseToken(value) != ""
}

func parseToken(value string) string {
	return strings.TrimSpace(value)
}

func (s *Service) ValidateToken(value string) bool {
	return ValidateToken(value)
}

func (r Repository) Save(user User) error {
	if user.Email == "" {
		return ErrInvalidToken
	}
	return nil
}
