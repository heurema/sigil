export type ValidationResult = {
  ok: boolean;
  reason?: string;
};

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export function validateEmail(email: string): ValidationResult {
  const normalized = normalizeEmail(email);
  if (!normalized.includes("@")) {
    return { ok: false, reason: "missing-at-sign" };
  }
  return { ok: true };
}
