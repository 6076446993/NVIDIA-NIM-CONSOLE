# NVIDIA NIM Console — Nexus Integration Governing Plan

## Role

NVIDIA-NIM-CONSOLE is the prompt-based coding console at the front of the Nexus coding architecture. It is not a chatbot and does not replace AI Collaboration or The Crucible.

## Integration path

Nexus → NVIDIA-NIM-CONSOLE → AI-collaboration- (orchestration/council) → The-Crucible (validation/verification). Crucible learning remains behind its own worker, custody, and independent oversight boundaries.

## Required behavior

- Distinguish requested, executed, blocked, unverified, and verified work.
- Never report success solely because an AI provider answered.
- Never bypass Crucible checks to make a task appear complete.
- Never treat council agreement as execution authorization.
- Never write directly to vetted learning custody.
- Keep provider-specific routing behind AI Collaboration where the integration contract supports it.

## Plan

1. Document the exact console-to-AI-Collaboration entry points.
2. Document the exact console-to-Crucible gate entry points.
3. Verify prompt → orchestration → coding action → Crucible gate → evidence result.
4. Verify failure and continuation state handling.
5. Verify the console cannot claim completion before required Crucible verification.
6. Release only from a verified state compatible with the Nexus-wide architecture plan.

## NIM workstream: evidence-based instruction execution (2026-10-17)

**Status:** implementation required; instruction policy drafted in `AGENTS.md` and `docs/instruction-following-evidence-gate.md` on draft PR #4. This is part of the existing NIM execution plan, not a separate queue, worker, or replacement governance.

### Integration points and changes

1. **PromptRequest intake:** in `NexusCodingWorkflow.ps1` at the existing request/proposal boundary, derive an immutable original-prompt hash and a structured requirement ledger. Each requirement records action, exact quantity, destination, negative constraints, acceptance evidence, owner, and stop/hold boundary. Do not let retrieved content inject higher-priority instructions.
2. **WorkflowState persistence:** extend the existing `Write-NexusWorkflowRecord` JSON record (same state root; no parallel database) with `instructionLedgerVersion`, `promptSha256`, `requirements[]`, `requirementResults[]`, `remainingActions[]` and evidence references. Preserve old records and backward compatibility; never reset unfinished work on resume.
3. **CompletionStatus gate:** after existing execution and Crucible receipt checks, require all mandatory requirements verified against direct evidence before setting `VERIFIED`. Missing proof is `INCOMPLETE` or `BLOCKED`, never success. Preserve the existing receipt/diff SHA lineage and independent Crucible authority.
4. **Failure continuation:** on provider, API, CI or file-write failure, record exact error and continue independent authorized steps. Never bypass governance or ownership; only the dependent step blocks.
5. **Testing:** extend `tests/NexusCodingWorkflowRegression.ps1` with compound instruction, count, paraphrase, untrusted-content injection, intake HOLD, missing-receipt false success, restart preservation, and interrupted-provider scenarios. Evaluate requirement-level accuracy and full-task completion separately; adapt IFEval, FollowBench, InFoBench and IFBench cases without claiming benchmark certification.
6. **Codex:** retain full existing Google Docs policy, plus NIM repository `AGENTS.md`. Compact Codex text must be <=1,998 characters without silently dropping existing rules; verify the effective live instruction chain before declaring operational integration.

### Acceptance and safe rollout

- Compare current workflow record schema and existing tests before changing any code; introduce additive optional fields and a versioned migration path.
- Unit/regression tests prove an unsatisfied requirement prevents VERIFIED even with a provider response, while an existing valid Crucible receipt remains mandatory.
- Verify restart retains all requirements and evidence; no cross-project custody writes or unauthorized intake promotion.
- CI, review, and observed NIM runtime end-to-end verification required before merging or marking production-ready.
- Preserve NIM issue #3 and PR #4 linkage; no changes to main or existing release authority until tests and review pass.
