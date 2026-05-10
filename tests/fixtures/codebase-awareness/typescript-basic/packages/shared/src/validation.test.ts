import { describe, expect, it } from "vitest";
import { validateEmail } from ".";

describe("validation", () => {
  it("validates email", () => {
    expect(validateEmail("user@example.com").ok).toBe(true);
  });
});
