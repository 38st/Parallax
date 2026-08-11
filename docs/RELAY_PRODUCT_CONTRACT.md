# Relay local MVP contract

Relay is a local, serial software-change pipeline inside Parallax:

`Scout -> Implement -> Verify -> Review -> Ready for your inspection`

Rejected verification or review returns the task to a fresh Implement attempt.
Relay, not an agent, owns state transitions, repository custody, evidence, and
the final readiness decision.

## Supported scope

- One active Relay globally.
- One clean local Git repository with a resolved commit and no submodules or
  required Git LFS downloads.
- One Parallax-owned detached worktree, preserved after stop or completion.
- One explicitly selected Codex identity for the whole task.
- Stable stdio Codex app-server transport only.
- Network disabled and external tools unavailable by default.
- A fixed Scout, Implement, Verify, Review pipeline.
- A local evidence package, worktree, and exportable patch as the final
  artifact.

Relay does not create commits, mutate user branches, push, open pull requests,
merge, deploy, clean up worktrees, run parallel agents, or accept a user-defined
pipeline in this MVP.

## Trust boundary

Agents, repository contents, repository tests, model output, tool output, and
logs are untrusted input. Relay may claim restricted execution only after its
configured sandbox capability has been positively verified. If that boundary
cannot be proved, executable stages are unavailable and the UI must describe
the environment as unsupported rather than silently broadening authority.

The trusted computing base is limited to the Relay reducer and journal, the
managed-workspace broker, the process/evidence broker, the Codex transport,
and explicit human decisions. Agent prose is a claim and never evidence.

## Stage authority

| Stage | Workspace | Network | May approve itself |
| --- | --- | --- | --- |
| Scout | Read-only | No | No |
| Implement | Managed worktree write | No | No |
| Verify | Managed worktree write for derived output; source mutations invalidate the attempt | No | No |
| Review | Read-only | No | No |

Approval decisions are per request. Session-wide approval and automatic
authority escalation are outside the MVP.

## Ready contract

The engine may emit `readyForInspection` only when one atomic validation proves
all of the following:

1. Scout produced an accepted scope and verification plan.
2. Implement produced a non-empty source change.
3. Verify cited successful Relay-captured command evidence.
4. A fresh Review attempt approved the exact verified workspace digest.
5. Every finding is resolved or explicitly waived by a recorded human decision.
6. No turn, command, approval, or external action remains in flight.
7. The preserved worktree still recomputes to the approved digest.
8. The append-only journal and evidence objects validate the complete chain of
   custody.

Any relevant workspace mutation after Verify invalidates Verify and Review.
Any mutation after Review returns the task to Verify. `Ready for your
inspection` does not mean committed, pushed, merged, deployed, or production
ready.

## Recovery contract

- Persist intent before starting an external effect.
- On restart, previously active tasks first become `reconciling`.
- An attempt without a proven terminal event becomes `interrupted`; it is never
  resumed or approved silently.
- Retry creates a new immutable attempt.
- Stop interrupts and reaps owned processes, resolves pending decisions as
  canceled, and preserves the worktree and evidence.
- Missing, corrupt, stale, or unverifiable evidence blocks progression and is
  preserved for diagnosis.

## Product status axes

Execution status and delivery status are separate. A local Ready task can have
`localEvidenceCaptured` delivery status; it cannot display `delivered` without
independent external-delivery evidence. `Running` requires a live owned attempt
lease. Unknown or stale liveness is `reconciling`, `stalled`, or `interrupted`,
never optimistically Running.

## Post-MVP boundary

GitHub delivery is a separate increment: explicit commit approval, a
user-selected branch, draft pull request creation, exact-SHA CI observation,
review ingestion, and remediation. It must use the same immutable baton and
evidence model and cannot weaken the local Ready contract.
