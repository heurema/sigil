import { validateEmail } from "@acme/shared/validation";

export function SignupForm(props: { email: string }): boolean {
  return validateEmail(props.email).ok;
}
