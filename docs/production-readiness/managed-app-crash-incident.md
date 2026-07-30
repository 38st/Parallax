# Managed ChatGPT crash incident — July 28, 2026

## Executive finding

Three inspected ChatGPT `.ips` reports show failures in a native macOS
remote-hosted Picture-in-Picture/XPC path. Two report
`EXC_BREAKPOINT`/`SIGTRAP`; one reports `EXC_BAD_ACCESS`/`SIGSEGV`. Evidence
mentions `RemoteHostedPIPContentService` and
`com.openai.codex.remote-hosted-pip-content`. No inspected report contains a
Parallax image or proves Parallax caused the fault.

Root-cause confidence:

- **High:** the immediate fault is inside the managed ChatGPT/native remote
  hosting path.
- **High:** Parallax previously under-handled the operational consequences of
  an unexpected managed-process exit.
- **Low / unsupported:** Parallax caused the native crash.

## Timeline and containment

- July 28, 2026: repeated managed ChatGPT terminations observed.
- Three local reports inspected; exact paths are intentionally omitted from
  shareable documentation.
- Temporary external containment was applied to affected regular and managed
  profiles:
  `desktop.computerUseAlwaysHidePictureInPicture = true`.
- This review added generic per-profile workaround records. Parallax records
  verified state but does not edit the third-party setting.

## Ownership boundary

The managed application/vendor owns its native/XPC implementation and the
underlying defect. Parallax owns:

- exact application/profile/process attribution;
- profile-scoped containment and durable activity gates;
- expected-versus-unrequested termination state;
- sanitized crash-report reference and status;
- conservative automatic recovery and safe manual reopen;
- retry backoff, rate limiting, and crash-loop protection;
- durable, visible workaround metadata;
- truthful language that separates Parallax failure from managed-app failure.

## Pre-fix failure modes

1. Every observed termination became a normal “closed” event.
2. An immediate exit could lose `ProcessStartIdentity`, preventing report
   linkage.
3. Automatic recovery/backoff did not exist.
4. A post-open tracking failure released the activity gate while the process
   remained alive.
5. Two Parallax processes could race to open the same profile.
6. One process could be claimed by different profile requests.
7. An interrupted opening receipt could make the whole library
   recovery-required.
8. Workaround state was external and invisible to Parallax.

## Implemented recovery design

### Detection and attribution

`TrackedApplicationLaunch` retains the accepted process and marks termination
expected only after Parallax successfully requests quit for that exact
PID/start/application instance. Other exits are “unexpected,” not automatically
called crashes.

`LaunchHistoryEntry` persists both the full start identity when available and
the observed PID for immediate exits. `ApplicationCrashReportLocator` links:

- full identity: exact PID, compatible bundle, and launch start within five
  seconds; or
- fallback identity: exact PID, exact bundle (or exact process name when no
  bundle exists), bounded launch/capture time, and exactly one compatible
  report.

Ambiguous or missing evidence remains unlinked. Reports are never copied into
Parallax state; the UI keeps only parsed sanitized fields and the local report
reference.

### Containment

- Interprocess `flock` serializes durable request create/process
  record/completion/cleanup.
- The same stable profile is rejected across Parallax processes unless the
  exact expert risk acknowledgement authorizes concurrency.
- A live `ProcessStartIdentity` cannot belong to two launch requests.
- Post-open tracking degradation retains observer and lease until actual exit.
- Identity-scoped ambiguous receipts block only that profile; identity-less
  corruption remains global and fail-closed.

### Automatic recovery

Automatic recovery defaults enabled and can be disabled in Settings. It is
considered only after a two-second DiagnosticReports grace period and only when
strict attribution produces one matching crash report.

The stable recovery key is application storage UUID plus profile storage UUID.
Within a ten-minute rolling window:

1. first confirmed crash: retry after two seconds;
2. second confirmed crash: retry after eight seconds;
3. third confirmed crash: open the circuit and require manual review/Open
   Again.

An intentional Parallax quit never retries. An in-app quit with no matching
crash report never retries. Recovery budgets do not cross profiles.

### Manual recovery and session scope

Recent Activity displays “Ended Unexpectedly” even if macOS did not produce a
report. “Open Again” resolves the exact application/profile logical and storage
identities against the current library before opening. Parallax cannot promise
that a third-party app restores a particular account, window, or task; it can
promise that it reopens the same isolated profile data and launch
configuration.

### Workaround state

`ManagedAppWorkaroundStore` persists generic, versioned records with stable
application/profile identity, ID, display name, definition version,
configuration reference, lifecycle state, timestamp, and bounded operator
note. Storage is `0700`/`0600`; corrupt documents are quarantined.

The App Settings screen lets an operator record or remove the July 2026
workaround verification per profile. The copy explicitly states that Parallax
does not apply or roll back the vendor setting. Future workaround IDs/versions
round-trip without a schema change.

## Regression evidence

- `LaunchLifecycleTests`: immediate exit, expected quit state plumbing,
  degraded tracking, lease retention, reverse termination.
- `ProfileActivityRegistryTests`: separate-process atomic exclusion, process
  ownership uniqueness, PID reuse, corrupt receipts, scoped ambiguity,
  symlink/root swaps.
- `ApplicationCrashReportLocatorTests`: full start identity, bundle rejection,
  unique immediate-exit fallback.
- `LaunchHistoryStoreTests`: durable identity/PID, unexpected presentation,
  corruption quarantine.
- `ManagedAppRecoveryPolicyTests`: deterministic backoff, circuit breaker,
  rolling-window reset, profile isolation.
- `ManagedAppWorkaroundStoreTests`: persistence, future ID/version,
  cross-profile isolation, removal, corruption quarantine, permissions.
- Full suite: 616 tests, zero failures.

## Residual risks

- macOS may delay or omit a crash report; the safe result is manual recovery,
  not an unsafe restart.
- A user can quit inside the managed app without Parallax receiving explicit
  intent; this is shown as unexpected but is not auto-restarted without crash
  evidence.
- The recovery budget is a durable, advisory-locked ledger keyed by immutable
  application/profile storage identities. Restarting Parallax or opening a
  second Parallax process preserves the same rolling-window circuit state.
  Corrupt ledger evidence is preserved and automatic recovery pauses safely.
- The external workaround may become obsolete or change semantics. Operators
  must verify it against the affected vendor version before recording state.
