import { normalizeEmail, validateEmail } from "../../src/shared/validation";

describe("validation helpers", () => {
  it("normalizes email addresses", () => {
    expect(normalizeEmail(" USER@EXAMPLE.COM ")).toBe("user@example.com");
  });

  it("rejects email values without an at sign", () => {
    expect(validateEmail("missing-domain").ok).toBe(false);
  });
});
