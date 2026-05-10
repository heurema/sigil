import { validateEmail } from "@acme/shared/validation";

const validation = require("@acme/shared/validation");

export function runCli(email: string): number {
  return validateEmail(email).ok && validation.validateEmail(email).ok ? 0 : 1;
}
