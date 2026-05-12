# Basic contract example

`contract.json` is a minimal static shape example for a file-backed Signum contract. It is not enough by itself to run the full Signum pipeline without the surrounding user request, project context, approval flow, and runtime orchestration.

For exact contract schema behavior and runtime semantics, see `docs/reference.md`.

Normal runs import or generate contracts into the active contract artifact root under `.signum/contracts/<contractId>/`.
