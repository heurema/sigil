import { validateEmail, normalizeEmail as normalize } from "@acme/shared/validation";

const sharedValidation = require("@acme/shared/validation");

export async function createUserSignup(email: string): Promise<string> {
  const dynamicValidation = await import("@acme/shared/validation");
  const normalized = normalize(email);
  if (!validateEmail(normalized).ok || !dynamicValidation.validateEmail(normalized).ok) {
    throw new Error("invalid email");
  }
  return sharedValidation.normalizeEmail(normalized);
}

export default class SignupService {
  create(email: string): Promise<string> {
    return createUserSignup(email);
  }
}
