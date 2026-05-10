export interface EmailValidationResult {
  ok: boolean;
  reason?: string;
}

export type UserId = string;

export enum Role {
  Admin = "admin",
  User = "user"
}

export function validateEmail(email: string): EmailValidationResult {
  const normalized = normalizeEmail(email);
  return normalized.includes("@") ? { ok: true } : { ok: false, reason: "missing-at" };
}

export const normalizeEmail = (email: string): string => {
  return parseToken(email).toLowerCase();
};

export class ValidationService {
  validate(email: string): EmailValidationResult {
    return validateEmail(email);
  }
}

function parseToken(value: string): string {
  return value.trim();
}

const formatValidationMessage = (reason: string): string => {
  return `validation:${reason}`;
};

export default function validationHandler(email: string): EmailValidationResult {
  return validateEmail(email);
}
