import { normalizeEmail, validateEmail } from "../shared/validation";

export function createSignupPayload(email: string) {
  const result = validateEmail(email);
  if (!result.ok) {
    throw new Error(result.reason || "invalid-email");
  }
  return {
    email: normalizeEmail(email),
  };
}
