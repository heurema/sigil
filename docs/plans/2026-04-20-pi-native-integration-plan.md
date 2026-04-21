# Signum for pi — Native Extension Implementation Plan

> **For agentic workers:** keep this workstream bounded. Do **not** combine: (1) pi runtime work, (2) large deterministic-core rewrites, and (3) unrelated root pipeline changes in one diff. Implement in slices.

**Goal:** Add first-class pi support directly in this repository, expose Signum as a native `/signum` command inside pi, and make the repo installable as a pi package via npm.

**Architecture:** Keep the root repo as the canonical Signum source. Add a new `platforms/pi/` runtime surface implemented as a TypeScript pi extension. Use code-based orchestration in TypeScript, not a skill or prompt-template entrypoint. Reuse shared deterministic `lib/*` scripts through TypeScript adapter modules for the first tranche. Publish from the repo root with a `pi` manifest that points at the pi extension entrypoint.

**Tech Stack:** TypeScript (ESM), pi extension API, pi SDK, Node.js `child_process`, existing bash/jq/python deterministic scripts, npm packaging.

**Primary UX decision:** no skills for the main entrypoint. The user-facing interface is a native pi command:

```text
/signum explain
/signum init --harness
/signum <task>
/signum archive <contractId>
/signum close <contractId>
```

---

## Locked Decisions

1. **Develop in this repo**, not in a separate `signum-pi` fork/repo.
2. **Primary interface is `/signum`**, implemented as a pi extension command.
3. **No skill-based primary entrypoint** for the pi integration.
4. **Publish from repo root via npm** so users can install through `pi install npm:...` later.
5. **Reuse `lib/*` first**, rather than rewriting the entire deterministic core to TypeScript now.
6. **Runtime policy enforcement must be TS-native** during engineer execution; post-hoc shell checks alone are insufficient.
7. **`platforms/pi/` is an overlay/runtime surface**, not a new canonical source of pipeline truth.

---

## Non-Goals for the First Tranche

- No full TypeScript rewrite of `lib/*`
- No separate standalone Signum app outside pi
- No separate npm package repo unless the pi runtime later outgrows this repo
- No skill-only or prompt-template-only Signum workflow for pi
- No attempt to merge pi and Claude runtime surfaces into one shared command file
- No broad redesign of contract/proofpack schemas just for pi packaging

---

## Delivery Strategy

Ship this in **bounded slices**:

1. **Package + extension foundation**
2. **Command surface + init/explain/archive/close**
3. **Role session launcher + CONTRACT flow**
4. **Engineer execution boundary + policy enforcement**
5. **AUDIT + PACK integration**
6. **Docs, packaging, release hardening**

This keeps the work aligned with repo policy: do not mix docs, deterministic-core rewrites, and orchestration changes all at once.

**Status as of 2026-04-21:** Slices 1–6 are complete for the pi-native MVP. Deferred or follow-up work remains for iterative AUDIT parity, optional custom UI, broader test coverage, and npm publish-path decisions.

---

## Target Layout

```text
package.json
platforms/
  pi/
    README.md
    extensions/
      signum/
        index.ts
        orchestrator.ts
        args.ts
        models.ts
        ui.ts
        state.ts
        paths.ts
        phases/
          explain.ts
          init.ts
          contract.ts
          execute.ts
          audit.ts
          pack.ts
          archive.ts
          close.ts
        runtime/
          role-session.ts
          policy-tools.ts
          script-adapters/
            anti-entropy.ts
            dsl.ts
            init-scan.ts
            policy-scan.ts
            contract-dir.ts
    agents/
      contractor.md
      engineer.md
      reviewer-semantic.md
      reviewer-security.md
      reviewer-performance.md
      synthesizer.md
      init-synthesizer.md
```

Notes:
- `platforms/pi/agents/` are runtime prompt assets for pi; they are **not** exposed as user skills.
- Shared deterministic assets remain in root `lib/`.
- If tiny helpers are easier to port than reuse (for example contract index helpers), that is allowed only when it reduces orchestration complexity and keeps on-disk formats unchanged.

---

## Slice 1 — Package + Extension Foundation

### Task 1: Add npm package metadata at repo root

**Files:**
- Create: `package.json`
- Optional: `package-lock.json`

- [x] Add root `package.json` with:
  - package name (target: `@heurema/signum`, final name after availability check)
  - version aligned with Signum release versioning
  - `type: "module"`
  - `keywords` including `pi-package`
  - `pi.extensions` pointing to `./platforms/pi/extensions/signum/index.ts`
  - `files` allowlist including `platforms/pi/**`, `lib/**`, `agents/**`, `LICENSE`, and runtime-required docs/assets
- [x] Keep packaging explicit via `files`; avoid relying on implicit npm inclusion.
- [x] Add minimal scripts:
  - `check`
  - `pack:dry-run`
  - `test:pi` (placeholder allowed in first slice)
- [x] Verify `npm pack --dry-run` includes all runtime assets required by the extension.

### Task 2: Add pi platform scaffold

**Files:**
- Create: `platforms/pi/README.md`
- Create: `platforms/pi/extensions/signum/index.ts`
- Create: `platforms/pi/extensions/signum/orchestrator.ts`

- [x] Create the `platforms/pi/` directory structure.
- [x] Add a minimal extension entrypoint that registers `/signum`.
- [x] Add a minimal orchestrator skeleton that can route to subcommands.
- [x] Document local development in `platforms/pi/README.md`.

### Task 3: Verify local install path

- [x] Confirm local dev flow works with:
  - `pi --no-extensions -e ./platforms/pi/extensions/signum/index.ts`
  - `pi install . -l`
- [x] Record the expected local install workflow in `platforms/pi/README.md`.

**Exit criteria for Slice 1:**
- Repo can be treated as a pi package locally.
- pi loads the extension from this repo.
- `/signum` command is registered, even if it only prints a placeholder.

---

## Slice 2 — Native Command Surface

### Task 4: Implement argument parsing and subcommand routing

**Files:**
- Create: `platforms/pi/extensions/signum/args.ts`
- Modify: `platforms/pi/extensions/signum/orchestrator.ts`

- [x] Parse these forms:
  - `explain`
  - `init [--force] [--harness] [--project-root <path>]`
  - `archive [contractId]`
  - `close [contractId]`
  - default freeform task
- [x] Keep parsing deterministic and testable.
- [x] Reject ambiguous combinations with explicit user-facing messages.

### Task 5: Implement `/signum explain`

**Files:**
- Create: `platforms/pi/extensions/signum/phases/explain.ts`

- [x] Return a structured summary of the pi-native workflow.
- [x] Keep the output aligned with canonical Signum phases.
- [x] Do not claim pi-specific behavior that is not yet implemented.

### Task 6: Implement `/signum init`, `/signum archive`, `/signum close`

**Files:**
- Create: `platforms/pi/extensions/signum/phases/init.ts`
- Create: `platforms/pi/extensions/signum/phases/archive.ts`
- Create: `platforms/pi/extensions/signum/phases/close.ts`
- Create or reuse: `platforms/pi/extensions/signum/runtime/script-adapters/contract-dir.ts`

- [x] `/signum init`:
  - reuse `lib/init-scanner.sh` and `lib/init-harness-scaffold.sh`
  - use pi-native UI for review/accept flows
  - write files directly from the extension runtime, not via heredoc shell
- [x] `/signum archive` and `/signum close`:
  - keep `.signum/contracts/index.json` format compatible with existing Signum behavior
  - reuse shell helpers or port tiny directory/index helpers to TS without changing file formats
- [x] Confirm these paths work before starting the main task pipeline.

### Task 7: Add run-state detection + resume/restart flow

**Files:**
- Create: `platforms/pi/extensions/signum/state.ts`
- Modify: `platforms/pi/extensions/signum/ui.ts`

- [x] Detect:
  - no run
  - contract-only run
  - resumable run
- [x] Present user choice through `ctx.ui.select()`:
  - resume
  - restart
  - cancel
- [x] On restart, clear only the known `.signum/` working-set artifacts.
- [x] Preserve per-contract archives and completed proofpacks.

**Exit criteria for Slice 2:**
- `/signum explain`, `/signum init`, `/signum archive`, `/signum close` all work natively in pi.
- Resume/restart decision logic exists before default task execution is added.

---

## Slice 3 — Role Session Launcher + CONTRACT Flow

### Task 8: Build a reusable role session launcher

**Files:**
- Create: `platforms/pi/extensions/signum/runtime/role-session.ts`
- Create: `platforms/pi/extensions/signum/models.ts`
- Create: `platforms/pi/extensions/signum/paths.ts`

**Implementation choice:** use **pi SDK sessions** as the primary execution mechanism for contractor/engineer/reviewers/synthesizer.

- [x] Build a `RoleSessionRunner` abstraction that can:
  - launch an isolated pi agent session programmatically
  - choose model/provider per role
  - set role-specific tools
  - inject role prompt assets from `platforms/pi/agents/`
  - capture final text + structured tool events
- [x] Keep the launcher behind an interface so a subprocess fallback remains possible if SDK nesting proves unreliable.
- [x] Do not depend on skills to load role instructions.

### Task 9: Add pi-specific role prompt assets

**Files:**
- Create: `platforms/pi/agents/*.md`

- [x] Create pi-specific prompt assets for:
  - contractor
  - engineer
  - reviewer-semantic
  - reviewer-security
  - reviewer-performance
  - synthesizer
  - init-synthesizer
- [x] Normalize tool references to pi semantics (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`).
- [x] Preserve canonical Signum behavior wherever practical.
- [x] Document intentional pi-only deviations if they are required.

### Task 10: Implement CONTRACT phase in TypeScript

**Files:**
- Create: `platforms/pi/extensions/signum/phases/contract.ts`
- Create: `platforms/pi/extensions/signum/runtime/script-adapters/*.ts`

- [x] Run contractor role through the role session launcher.
- [x] Validate `.signum/contract.json` exists and is structurally valid.
- [x] Reuse deterministic checks from `lib/*` where already extracted:
  - contract injection scan
  - prose/glossary/terminology/overlap/assumption/ADR/staleness checks
- [x] Re-implement **inline orchestrator-only logic** from `commands/signum.md` as TS modules where no reusable `lib/*` exists yet:
  - spec quality scoring
  - holdout count gate
  - contract summary extraction
  - approval checklist handling
- [x] Use pi-native UI for the human approval checklist.
- [x] Write `.signum/approval.json` and anchor the contract hash after user approval.

### Task 11: Add `/signum <task>` happy-path entry into CONTRACT only

- [x] Wire the default `/signum <task>` path to stop after CONTRACT until approval and artifact writing are correct (completed during Slice 3 before later extension to full pipeline).
- [x] Do not begin engineer execution until CONTRACT flow is stable.

**Exit criteria for Slice 3:**
- `/signum <task>` can produce a contract, show a summary, ask for approval, and write the expected CONTRACT artifacts.
- No skills are involved in the entrypoint.

---

## Slice 4 — Engineer Execution Boundary + Runtime Policy Enforcement

### Task 12: Implement policy-aware tool wrappers

**Files:**
- Create: `platforms/pi/extensions/signum/runtime/policy-tools.ts`

- [x] Wrap engineer tools so runtime enforcement happens before mutation:
  - `read`
  - `edit`
  - `write`
  - `bash`
- [x] Enforce:
  - allowed paths from `inScope` / `allowNewFilesUnder`
  - deny patterns from `contract-policy.json`
  - path deletion rules for removals
  - file-count limits if policy requires them
  - optional network denial
- [x] Do not rely solely on prompt discipline for engineer scope control.

### Task 13: Implement EXECUTE phase using SDK session + wrapped tools

**Files:**
- Create: `platforms/pi/extensions/signum/phases/execute.ts`

- [x] Capture baseline deterministically before engineer execution.
- [x] Generate `contract-engineer.json` and `contract-policy.json`.
- [x] Launch engineer with the wrapped tool set.
- [x] Preserve existing `.signum/execute_log.json` and `.signum/combined.patch` behavior.
- [x] Support repair-loop attempts bounded by policy.

### Task 14: Add scope/policy violation handling

- [x] When engineer violates policy, stop the run cleanly with a structured message.
- [x] Persist violation data to `.signum/` artifacts.
- [x] Keep behavior compatible with existing proof/audit expectations.

**Exit criteria for Slice 4:**
- Engineer execution is runtime-constrained, not just post-hoc checked.
- Scope violations are blocked during execution.

---

## Slice 5 — AUDIT + PACK

### Task 15: Implement AUDIT phase orchestration

**Files:**
- Create: `platforms/pi/extensions/signum/phases/audit.ts`

- [x] Reuse deterministic shell/core steps where possible:
  - mechanic
  - policy scan
  - holdout execution
- [x] Launch reviewer roles in parallel where risk requires it.
- [x] Route reviewers to different model families/providers where available.
- [x] Keep reduced-coverage behavior explicit when providers are unavailable.

### Task 16: Implement synthesizer flow

- [x] Feed reviewer outputs + deterministic reports into a synthesizer role session.
- [x] Preserve Signum decision semantics:
  - `AUTO_OK`
  - `AUTO_BLOCK`
  - `HUMAN_REVIEW`
- [x] Keep reasoning structured and artifact-compatible.

### Task 17: Implement PACK phase

**Files:**
- Create: `platforms/pi/extensions/signum/phases/pack.ts`

- [x] Build `proofpack.json` in the same `.signum/` artifact model used by existing Signum.
- [x] Reuse anti-entropy report generation where possible.
- [x] Sync working-copy artifacts into per-contract directories.
- [x] Preserve archive/index compatibility.

### Task 18: Decide parity scope for iterative audit

**Decision for first shipping slice:**
- MVP may ship with **single-pass AUDIT** if iterative audit would delay the first usable pi-native release too much.
- Iterative audit must then be tracked as an explicit parity follow-up, not silently dropped.

- [x] If iterative audit is deferred, document the gap and keep the runtime architecture ready for it.
- [ ] If implemented immediately, do it in a dedicated slice after single-pass audit is stable.

**Exit criteria for Slice 5:**
- pi-native Signum can run the full task path through PACK for at least the MVP coverage target.

---

## Slice 6 — UI, Docs, Packaging, Release Hardening

### Task 19: Add pi-native UI affordances

**Files:**
- Create/Modify: `platforms/pi/extensions/signum/ui.ts`

- [x] Add phase progress status via `ctx.ui.setStatus()`.
- [ ] Add optional widget for current phase / checklist / reviewer progress.
- [x] Use `ctx.ui.confirm()` and `ctx.ui.select()` for approval and resume flows.
- [x] Keep the first version simple; custom overlay UI is optional follow-up work.

### Task 20: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/reference.md`
- Modify: `docs/PLANS.md`
- Modify as needed: `CHANGELOG.md`
- Create/Modify: `platforms/pi/README.md`

- [x] Add pi install/use documentation.
- [x] Keep root docs explicit about canonical vs overlay behavior.
- [x] Document that pi support is command-first, not skill-first.
- [x] Document package install and local dev/test workflow.

### Task 21: Add tests

**Files:**
- Create: pi-specific test harness under `tests/` or `platforms/pi/tests/`

- [ ] Add adapter tests for shared script wrappers.
- [ ] Add argument parser tests.
- [ ] Add artifact-state tests for resume/restart/archive/close.
- [ ] Add at least one end-to-end smoke test for `/signum explain` and `/signum init`.
- [ ] Add at least one fixture-driven task smoke test for CONTRACT-only and full pipeline MVP.
- [x] Add `npm pack --dry-run` verification to release/test workflow.

### Task 22: Prepare npm publish path

- [x] Verify package contents are stable.
- [ ] Confirm final npm name availability.
- [ ] Decide whether the first release is:
  - published under the canonical Signum package name, or
  - published under a temporary preview tag.
- [ ] Document install command for end users.

**Exit criteria for Slice 6:**
- Repo can be packed and locally installed as a pi package.
- Docs explain how pi support is installed and used.

---

## MVP Scope Recommendation

To avoid stalling the workstream, the first pi-native release should target this minimum scope:

### Required for MVP
- Root npm package installable by pi
- Native `/signum` command
- `/signum explain`
- `/signum init --harness`
- `/signum archive`
- `/signum close`
- `/signum <task>` through CONTRACT -> EXECUTE -> AUDIT -> PACK
- Runtime policy-wrapped engineer tools
- Reuse of shared `lib/*` scripts through TS adapters

### Allowed to defer after MVP
- Iterative audit loop parity
- Fancy custom overlay UI
- Large-scale TypeScript port of deterministic scripts
- Separate standalone Signum app outside pi

---

## Acceptance Criteria for This Workstream

The workstream is successful when all of the following are true:

1. A user can install the current repo as a pi package locally.
2. A user can invoke Signum in pi through `/signum`, with no skill required.
3. The pi runtime keeps `.signum/` artifact layout compatible with existing Signum expectations.
4. Engineer execution is constrained by real runtime policy wrappers.
5. Shared deterministic scripts are reused successfully through TS adapters.
6. npm packaging includes all runtime assets needed by the pi extension.
7. The implementation lives in this repo and does not require a parallel fork.

---

## Risks and Mitigations

### Risk: SDK session nesting is harder than expected
**Mitigation:** keep a thin `RoleSessionRunner` interface so subprocess-backed pi sessions remain a fallback.

### Risk: packaging omits runtime assets (`lib/*`, prompt files)
**Mitigation:** use `files` allowlist + `npm pack --dry-run` in tests.

### Risk: engineer policy enforcement is weaker than Claude runtime assumptions
**Mitigation:** implement wrapped tools before claiming full task-path support.

### Risk: parity drift between root Signum prompts and pi prompt assets
**Mitigation:** document pi-specific prompt assets as overlay/runtime assets and review intentional deviations.

### Risk: big-bang scope creep
**Mitigation:** ship bounded slices and keep iterative audit / custom UI as explicit follow-up work if needed.

---

## Current Next Steps

The MVP slices in this plan are complete. The next bounded follow-up work should be:
- land verify-dialect normalization and simplify compatibility-heavy EXECUTE verification logic
- implement iterative AUDIT parity in a dedicated slice
- expand pi-specific tests (argument parsing, adapter coverage, resume/restart, and `/signum init` smoke coverage)
- finalize npm publish-path decisions and document the end-user install command

Keep these as separate bounded follow-ups rather than reopening the original MVP slice as one large diff.
