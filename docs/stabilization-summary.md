# Signum Stabilization Summary

This page summarizes the current hardening baseline after the recent remediation sequence. It is a factual stabilization inventory, not a claim of full production certification.

## Current status

Signum is now a safer stabilized baseline for local deterministic development and review workflows. Version/schema metadata, DSL execution, CI wiring, project-root resolution, artifact paths, proofpack validation, policy scanner contracts, init scanning, command rendering, GitHub Action refs, runner labels, and clean-room release/package smoke now have static or fixture-backed regression guards.

The clean-room smoke guard is included in deterministic CI through `tests/test-cleanroom-smoke.sh`, which is discovered by `scripts/run-deterministic-tests.sh`. It remains local and deterministic: no real release, Emporium push, secrets, network, or external AI CLIs are required.

The remaining risk is mostly in explicitly bounded legacy compatibility, regex-based scanning, external provider availability, and workflow/toolchain immutability that cannot be fully guaranteed by repository files alone.

## Fixed findings

| Finding ID | Current protection | Guard |
| --- | --- | --- |
| `version-schema-drift` | Runtime schema/signum metadata is checked against plugin/schema sources. | `tests/test-metadata-consistency.sh` |
| `dsl-exec-timeout` | `exec` DSL steps are validated and run with deterministic timeout handling. | `tests/test-dsl-runner.sh` |
| `deterministic-pr-ci` | PR CI runs local deterministic tests, including clean-room smoke, with read-only permissions and no AI CLI/secrets dependency. | `.github/workflows/ci.yml`, `tests/test-ci-workflow.sh` |
| `unsafe-home-project-scan` | Project resolution uses explicit project root, git root, or current directory only. Home-directory auto-scan markers are forbidden. | `tests/test-project-root-resolution.sh` |
| `claude-cli-floating-install` | Generated Signum gate template installs a pinned Claude Code CLI version from `lib/tool-versions.env`. | `tests/test-toolchain-pinning.sh` |
| `root-artifact-legacy-drift` | Root `.signum/*` usage is inventoried and separated from canonical `.signum/contracts/<contractId>/` runtime artifacts. | `docs/artifact-path-inventory.md`, `tests/test-artifact-path-inventory.sh` |
| `normal-runtime-legacy-helper-calls` | Normal-runtime reset/sync paths use canonical-only helpers instead of legacy root compatibility helpers. | `docs/legacy-root-helper-callsite-inventory.md`, `tests/test-legacy-root-helper-callsites.sh` |
| `proofpack-validation-gap` | Proofpack shape, required receipt-compatible fields, artifact refs, metadata drift, and optional `removalEvidence` shape are validated. | `scripts/validate_proofpack.py`, `tests/test-proofpack-validation.sh` |
| `policy-scanner-unstable-rules` | Policy rules have stable `ruleId` values, a rule catalog, suppression syntax, and fixture coverage. | `lib/policy-rules.json`, `tests/test-policy-scanner.sh` |
| `init-harness-heredocs` | Init harness markdown content was extracted into checked-in templates with golden output coverage. | `lib/templates/init-harness/`, `tests/test-init-harness-scaffold.sh` |
| `init-scanner-shell-heavy` | The scanner implementation is Python stdlib behind the compatibility shell wrapper, with golden fixtures. | `scripts/init_scanner.py`, `tests/test-init-scanner.sh` |
| `github-actions-mutable-refs` | External GitHub Actions refs are pinned to full commit SHAs and tracked in an inventory. | `tests/fixtures/github-action-pins.json`, `tests/test-github-action-pinning.sh` |
| `github-runner-latest-labels` | Scanned GitHub-hosted runner labels use fixed `ubuntu-24.04`, not `ubuntu-latest`. | `tests/fixtures/github-runner-labels.json`, `tests/test-github-runner-pinning.sh` |

## Bounded exceptions

| Finding ID | Bound | Guard |
| --- | --- | --- |
| `final-output-root-cleanup` | Root-only Final Output legacy cleanup is exactly 3 `purge_root_working_set_views` calls. They are cleanup-only after finalize/archive/delete choices and are not normal-runtime sync/import behavior. | `docs/legacy-root-helper-callsite-inventory.md`, `tests/test-legacy-root-helper-callsites.sh`, `tests/test-signum-command-structure.sh` |
| `optional-removal-evidence` | `removalEvidence` is optional and root-only. The validator accepts absence and validates shape when present. | `docs/signum-command-structure.md`, `tests/test-proofpack-validation.sh` |
| `platform-overlay-drift` | Claude overlay has overlay-only `RECONCILE`. This is documented as a platform overlay deviation instead of forcing root parity. | `docs/overlay-deviations.json`, `tests/test-signum-fragment-parity.sh` |
| `release-cross-repo-push` | Release workflow still contains the Emporium cross-repo push path, but it is gated by repository check, read-only default permissions, dry-run mode, explicit SSH key requirement outside dry-run, clean-room local smoke, and smoke/static checks. | `.github/workflows/release-guardrails.yml`, `tests/test-release-workflow-hardening.sh`, `tests/test-cleanroom-smoke.sh` |
| `policy-scanner-false-positives` | Scanner is still regex-based. Stable rule IDs, local suppressions, and dependency file-scope reduce noise but do not make it a full parser. | `lib/policy-rules.json`, `tests/test-policy-scanner.sh` |
| `signum-command-monolith` | Command files are still large, but rendering is manifest-driven and byte-for-byte checked. Fragment divergence is inventoried before deeper semantic refactor. | `scripts/render_signum_command.py`, `tests/test-signum-command-renderer.sh`, `tests/test-signum-fragment-parity.sh` |
| `full-runner-immutability` | `ubuntu-24.04` removes `ubuntu-latest` drift, but GitHub-hosted image patch contents remain mutable outside this repo. | `tests/test-github-runner-pinning.sh` |

## Deferred limitations

- `full-runner-immutability`: full runner and toolchain immutability is not implemented. Fixed labels and pinned Actions do not freeze hosted image packages or OS patch contents.
- `policy-scanner-false-positives`: the policy scanner is still not a full parser and can miss or over-match language-specific semantics.
- `init-scanner-go-sum`: `go.sum` is not captured by the init scanner manifest signals.
- `signum-command-monolith`: full command semantic refactor is not done. Current fragments are a safe rendering/parity baseline.
- `release-cross-repo-push`: release cross-repo push still exists, though hardened and dry-run capable.
- `provider-availability-external`: optional reviewer/provider availability remains external to Signum and can be unavailable because of CLI auth, version, or network state.

## Regression guard matrix

| Key risk | Guard |
| --- | --- |
| Metadata drift between runtime, schema, plugin, and docs | `tests/test-metadata-consistency.sh` |
| DSL runner validation and `exec` timeout behavior | `tests/test-dsl-runner.sh` |
| Deterministic PR CI without secrets or AI CLIs | `tests/test-ci-workflow.sh` |
| Unsafe home project-root scanning regression | `tests/test-project-root-resolution.sh` |
| Floating Claude Code CLI install in generated gate workflow | `tests/test-toolchain-pinning.sh` |
| Release workflow hardening and dry-run behavior | `tests/test-release-workflow-hardening.sh` |
| Release/package clean-room dry-run from copied source in deterministic CI | `scripts/run-cleanroom-smoke.sh`, `tests/test-cleanroom-smoke.sh`, `tests/test-ci-workflow.sh` |
| Root `.signum` artifact path inventory drift | `tests/test-artifact-path-inventory.sh` |
| Legacy root helper call-site drift | `tests/test-legacy-root-helper-callsites.sh` |
| Proofpack shape, metadata, artifact refs, and optional removal evidence | `tests/test-proofpack-validation.sh` |
| Policy rule IDs, suppressions, dependency file-scope, and known regex behavior | `tests/test-policy-scanner.sh` |
| Init harness template extraction output parity | `tests/test-init-harness-scaffold.sh` |
| Init scanner Python wrapper/output behavior | `tests/test-init-scanner.sh` |
| Command renderer byte-for-byte output and manifest safety | `tests/test-signum-command-renderer.sh` |
| Root/overlay fragment parity and bounded divergence | `tests/test-signum-fragment-parity.sh` |
| External GitHub Actions SHA pinning | `tests/test-github-action-pinning.sh` |
| GitHub-hosted runner label pinning | `tests/test-github-runner-pinning.sh` |
| Command structure markers, overlay RECONCILE, and root cleanup count | `tests/test-signum-command-structure.sh` |

## Recommended next steps

1. Decide whether to stop at stable MVP or fund another hardening pass.
2. Optional: parameterize more command fragments only after preserving byte-for-byte renderer checks.
3. Optional: improve the policy scanner toward parser-aware matching for high-value languages.
4. Optional: run `SIGNUM_CLEANROOM_FULL=1 bash scripts/run-cleanroom-smoke.sh` in a clean pre-publish environment for the full deterministic suite. The default CI guard already runs targeted clean-room smoke and performs no real release, no Emporium push, and requires no secrets, network, or external AI CLIs.
5. Optional: define an enterprise data-egress policy for optional external reviewers.

## Certification note

This summary describes stronger regression guard coverage and known bounds. It does not certify Signum as fully production-ready, fully supply-chain immutable, or complete for regulated environments.
