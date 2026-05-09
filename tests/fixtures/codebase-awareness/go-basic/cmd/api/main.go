package main

import (
	"context"
	"fmt"

	auth "example.com/signum-go-basic/internal/auth"
	"example.com/signum-go-basic/pkg/validation"
	_ "github.com/acme/external/driver"
	_ "net/http/pprof"
)

func main() {
	service := &auth.Service{}
	if err := run(context.Background(), service, "ops@example.com"); err != nil {
		fmt.Println(err)
	}
}

func run(ctx context.Context, service *auth.Service, email string) error {
	if !service.ValidateToken("token") {
		return auth.ErrInvalidToken
	}
	if !validation.ValidateEmail(email) {
		return fmt.Errorf("invalid email")
	}
	_ = ctx
	return nil
}
