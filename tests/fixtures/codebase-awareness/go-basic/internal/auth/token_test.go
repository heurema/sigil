package auth

import "testing"

func TestValidateToken(t *testing.T) {
	if !ValidateToken("token") {
		t.Fatal("expected token to validate")
	}
}

func BenchmarkValidateToken(b *testing.B) {
	for i := 0; i < b.N; i++ {
		ValidateToken("token")
	}
}

func FuzzValidateToken(f *testing.F) {
	f.Add("token")
	f.Fuzz(func(t *testing.T, value string) {
		_ = ValidateToken(value)
	})
}
