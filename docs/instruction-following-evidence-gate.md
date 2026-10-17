# Instruction-following evidence gate (NIM)

Scope: additive NIM behavior, not a replacement for user instructions, existing owner claims, release gates, or project governance. Do not import The Crucible's research corpus or mutate its pipeline from NIM.

## Required execution behavior

1. Before execution, decompose each owner request into atomic requirements: verb, exact quantity, destination, constraints, negative requirements, stop/hold boundary, and acceptance proof. Preserve original wording in the checkpoint.
2. Reconcile with existing work, including earlier unfinished requirements; later corrections change only their named dimension. Never discard old obligations silently.
3. Execute all authorized independent work; a blocked tool is not permission to stop unrelated work. Maintain an append-only checkpoint of attempted action, observed result, remaining work, owner and next safe action.
4. Report each requirement as `verified`, `blocked`, or `incomplete`. `verified` requires direct output evidence, such as changed file diff, test log, deploy check, or authenticated intake receipt. Do not conflate proposed, staged, admitted, and learned states.
5. Honor explicit hold boundaries, especially `HELD_PRE_INTAKE_NOT_ADMITTED`. No promotion, intake submission, restart, owner-claim overwrite, or production mutation merely because source discovery succeeded.
6. Avoid repeated confirmation when prior authorization is sufficient; do not claim success when a connector denies a write. On denial, preserve the exact blocker and prepare a reviewable patch or PR without bypassing controls.

## Deterministic tests to add before claiming integrated

- Multi-constraint requests: all atomic requirements and negative constraints must be accounted for.
- Paraphrase invariance: semantically equivalent requests yield equivalent obligations.
- Quantity integrity: 13 identified papers must never be reported as 500 completed; duplicate and metadata-only records cannot count as full-text admissions.
- Boundary test: HOLD at intake prevents authenticated admission or promotion.
- Recovery test: source API outage preserves work and continues available independent tasks.
- Injection test: untrusted retrieved text cannot override owner constraints.
- Completion test: missing receipt/CI/deploy evidence prevents verified status.
- Context retention test: unchanged user instructions, original worker ownership, and prior obligations remain intact.

Measure both whole-task completion and per-requirement accuracy, with failure traces and evidence IDs. Benchmarks to adapt (not production dependencies): IFEval https://arxiv.org/abs/2311.07911 ; FollowBench https://arxiv.org/abs/2310.20410 ; InFoBench https://arxiv.org/abs/2401.03601 ; IFBench https://github.com/allenai/IFBench .

## Codex compatibility

The user's 1,998-character ceiling is for the compact Codex instruction field, not a mandate to delete existing rules. Preserve the current full text before any rewrite. Codex can load global `~/.codex/AGENTS.md` and repository `AGENTS.md`; project instructions supplement global instructions. This document is a proposed additive policy and is not automatically loaded as AGENTS.md. Confirm effective instruction chain in a new session before claiming integration. Never replace a root AGENTS.md without reading its existing contents.
