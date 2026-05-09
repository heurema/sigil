package validation

import "testing"

func TestValidateEmail(t *testing.T) {
	if !ValidateEmail("dev@example.com") {
		t.Fatal("expected email to validate")
	}
}
