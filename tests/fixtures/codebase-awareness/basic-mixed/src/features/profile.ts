import { validateEmail } from "../shared/validation";

export function canAttachRecoveryEmail(email: string): boolean {
  return validateEmail(email).ok;
}
