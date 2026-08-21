# Parallax product contract

Status: accepted product scope for the macOS source preview, August 8, 2026.

This document defines which Parallax capabilities are supported, which remain
preview-quality, and which are deliberately outside the current product. User
interface copy, documentation, tests, and release claims must not exceed this
contract.

This contract records accepted product decisions. It does not, by itself, prove
that an implementation task, quality gate, or release operation is complete.
Implementation completion is tracked separately in the
[delivery ledger](DELIVERY_LEDGER.md) and requires the evidence defined there.

## Supported macOS surface: Local Spaces

Local Spaces is the primary supported product surface. It lets a person:

- add an installed Chromium-based browser, the OpenAI Codex desktop app, or a
  custom macOS application;
- create named spaces with stable application and space identities;
- prepare separate Chromium user-data or Codex home locations;
- review and explicitly approve imported launch configurations;
- open, supervise, and quit configurations while retaining lifecycle evidence;
- manage Parallax-owned space data through guarded, recoverable operations; and
- import supported library metadata and export supported library metadata or
  settings representations.

“Supported” identifies the product surface, not a claim that a distributable
binary is available. Parallax is currently built and evaluated from source.

### Local Spaces boundary

Local Spaces provides best-effort configuration and data separation. It is not
an operating-system sandbox or security boundary. A launched application can
ignore an option, reuse an existing singleton process, communicate with shared
services, or access resources available to the current macOS account.

Parallax may mutate only data inside its verified managed namespace. Explicit
external paths remain user-owned. The exact ownership and operation rules are
documented in [Isolation and data ownership](ISOLATION_AND_DATA.md).

## Preview macOS surface: local AI account tracking

The Control Center is a local account tracker for identities used on one Mac.
It is preview-quality and is not an enterprise administration console.

The accepted provider behavior is:

- **Codex:** each Parallax account record has an account-specific `CODEX_HOME`
  under
  `~/Library/Application Support/Parallax/AccountSessions/<account-id>/CodexHome`.
  Parallax can initiate the provider's normal ChatGPT sign-in and read status,
  rate-limit, reset, plan, and token-activity fields exposed by the locally
  installed Codex app-server.
- **Claude:** each Parallax account record has an account-specific
  `CLAUDE_CONFIG_DIR` under
  `~/Library/Application Support/Parallax/AccountSessions/<account-id>/ClaudeConfig`.
  Parallax invokes the installed Claude Code tool with that directory for the
  provider's normal sign-in, saved sessions, authentication status, and local
  `/usage` command. It can show the session, all-model weekly, and
  model-specific weekly limits returned by that provider tool. Parallax does
  not inspect or copy Claude OAuth tokens itself. Existing records from builds
  that used the ambient Claude identity require one account-specific sign-in
  after upgrade.

Tracked labels, provider status, and last-checked values are local metadata.
Removing a record removes only that metadata; it does not sign out, cancel a
subscription, revoke access, or change a provider account.

The preview must remain truthful when data is missing or stale. It must not be
used as the system of record for billing, access control, seat ownership, or
compliance decisions.

## Explicitly deferred enterprise scope

The current product does not provide:

- organization member or role synchronization;
- purchased, assigned, reserve, or reclaimable seat inventory;
- organization-wide utilization or at-risk-member recommendations;
- automatic or administrator-approved seat/capacity transfers;
- provider-side allocation, entitlement, billing, or access-control mutations;
- enterprise authorization roles or a multi-administrator audit ledger; or
- provider-admin-console replacement or compliance evidence.

Fictional organization, member, seat, or transfer data is not a production data
source and must not be presented as a supported feature.

Enterprise work can re-enter scope only after a reviewed product decision names
the authoritative provider capabilities, organization data source, identity and
authorization model, mutation semantics, audit/retention policy, privacy model,
failure recovery, and release gates. Until then, documentation and UI must not
imply that local tracking changes provider state.

## Distribution status

Public binary distribution is deferred. Source builds and locally verified
ad-hoc artifacts do not satisfy the public-release gate. A supported download
requires the exact reviewed source SHA, current local and CI evidence, approved
version/build metadata, Developer ID signing, notarization and stapling,
Gatekeeper verification, clean installation, representative upgrade and
rollback evidence, authenticated provenance, and explicit publication
authority. See [Build and release](BUILD_AND_RELEASE.md) and the
[release gate](production-readiness/release-gate.md).

## Separate platform train

Mobile work is governed by its own [status and release criteria](MOBILE_STATUS.md).
It is not part of this macOS product contract or macOS release claim.

## Contract verification

A release-candidate review must prove all of the following:

1. Every advertised feature maps to a reachable workflow and current test or
   manual verification evidence.
2. Local Spaces never claims operating-system isolation or ownership of
   external data.
3. Codex and Claude identity behavior is described separately and matches the
   provider process environment actually used.
4. No organization seat, member, recommendation, transfer, billing, access, or
   compliance claim appears as supported behavior.
5. Preview data is visibly local, provider limitations are explicit, and stale
   or failed refreshes are not represented as current provider truth.
6. Public-release language remains NO-GO until every external distribution gate
   has exact evidence and authorization.
