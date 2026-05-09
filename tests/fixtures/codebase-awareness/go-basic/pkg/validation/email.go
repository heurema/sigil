package validation

import "strings"

func ValidateEmail(value string) bool {
	return value != "" && strings.Contains(value, "@")
}

func normalizeEmail(value string) string {
	return strings.ToLower(strings.TrimSpace(value))
}
