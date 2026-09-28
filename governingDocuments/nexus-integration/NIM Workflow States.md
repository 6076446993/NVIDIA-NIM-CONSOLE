# NIM Workflow States

## Workflow State Model

REQUESTED

EXECUTED

BLOCKED

UNVERIFIED

VERIFIED

---

## Definitions

REQUESTED

Work has been submitted.

EXECUTED

Work has been performed.

BLOCKED

Execution cannot continue.

UNVERIFIED

Execution completed but verification is incomplete.

VERIFIED

Crucible verification completed successfully.

---

## Important Rule

AI output does not create VERIFIED state.

Provider agreement does not create VERIFIED state.

Only Crucible verification may create VERIFIED state.