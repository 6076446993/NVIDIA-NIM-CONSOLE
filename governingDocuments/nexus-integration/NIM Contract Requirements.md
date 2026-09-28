# NIM Contract Requirements

## Purpose

This document extracts the contract requirements imposed by NVIDIA-NIM-CONSOLE governance.

NIM is a prompt-based coding console.

NIM is not a chatbot.

NIM is an interface layer within the Nexus architecture.

---

## Required Contract Objects

NIM requires the following shared contract objects:

- PromptRequest
- WorkflowState
- VerificationResult
- EvidenceRecord
- CompletionStatus

---

## Consumed Contract Objects

NIM consumes but does not author:

- GovernanceDecision
- LearningCandidate
- LearningDelivery
- TrustState

---

## Completion Requirements

AI output is not completion.

Council agreement is not completion.

Completion requires Crucible verification.

---

## Verification Requirements

NIM shall never report success solely because an AI provider produced output.

Verification status must originate from Crucible verification processes.

---

## Architectural Position

Nexus
↓
NVIDIA-NIM-CONSOLE
↓
AI-collaboration-
↓
The-Crucible

NIM acts as an interface layer and routing layer.

NIM is not a verification authority.