# Midnight SSH Enhancement Plan

## Assumption

Use the pending Apple Developer account period to build everything that does not require Apple approval. Once the account is approved, only signing, notarization, App Store Connect, TestFlight, in-app purchases, and analytics setup should remain.

## 1. Distribution Strategy

Target two channels:

| Channel | Purpose | Notes |
| --- | --- | --- |
| Direct Mac download | Primary paid/pro app | Best fit because the current macOS app has sandbox disabled and uses SSH, local files, Rust bridge, terminal, and diagnostics. |
| Mac App Store | Later trust/discovery channel | May require a sandboxed or reduced-capability variant. |

Current repo status supports this path:

- `justfile` already has `mac-build-signed`, `mac-dmg`, and `mac-notarize`.
- `r-shell-macos/project.yml` has hardened runtime enabled but sandbox disabled.

## 2. While Developer Account Is Pending

### 2.1 Finalize Product Identity

- Confirm final bundle id before public release.
- Current bundle id is `com.r-shell.macos`.
- Decide whether to keep it or move to something like `com.midnightssh.mac`.
- If changing the bundle id, add migration for saved connections and Keychain entries.

### 2.2 Finish Direct-Distribution Packaging

Add a `just mac-release` task that runs:

- clean build
- release build
- DMG generation
- checksum generation
- release notes generation

Leave notarization as a no-op until Apple credentials exist.

### 2.3 Add Real Auto-Update

- Complete the placeholder `r-shell-macos/RShellApp/UpdateManager.swift`.
- Integrate Sparkle for direct distribution.
- Add appcast generation to release scripts.
- Add a "Check for Updates..." menu item.

### 2.4 Build Licensing Abstraction

Add an `EntitlementsStore` protocol.

Providers:

- `LocalTrialEntitlementsProvider`
- `LicenseKeyEntitlementsProvider`
- later `StoreKitEntitlementsProvider`

Gate premium features without hard-wiring App Store APIs.

### 2.5 Define Paid Tiers

Suggested tiers:

- Free: saved connections, terminal, SFTP, basic monitor.
- Pro: dashboard, deep diagnostics, service visualizations, multi-server desktop, editor, map, monitored services.
- Team/Business later: export/import profiles, encrypted sync, audit bundles, shared connection templates.

### 2.6 Add Privacy And Trust Features

- Add an in-app Privacy & Security page.
- Explain where credentials are stored.
- Add "Export diagnostics bundle" with redaction.
- Add optional analytics toggle, default off for direct builds.
- Add known-hosts and Keychain health checks.

### 2.7 Prepare Marketplace Assets

Create six screenshots:

- multi-server dashboard
- terminal and SFTP
- monitor pane
- systemd deep dive
- UFW/IP map
- file editor

Write App Store copy around this positioning:

> Mac-native SSH operations cockpit.

Create review/demo script and sample server data.

## 3. Immediately After Apple Approval

### 3.1 Create Developer ID Certificate And Notarization Credentials

Apple requires Developer Program membership for Developer ID distribution and notarization.

Reference: https://developer.apple.com/support/developer-id/

### 3.2 Run First Signed Direct Build

- Set `APPLE_SIGNING_IDENTITY`.
- Run `just mac-build-signed`.
- Run `just mac-dmg`.
- Run `just mac-notarize <dmg>`.
- Verify with `spctl`.

### 3.3 Create App Store Connect Records

- macOS app
- iOS/iPadOS app placeholder
- subscriptions or in-app purchase products if using App Store monetization
- privacy nutrition labels
- support URL and marketing URL

### 3.4 Enroll In Small Business Program If Eligible

Apple lists a reduced 15% commission for qualifying developers.

Reference: https://developer.apple.com/app-store/small-business-program/

## 4. App Store Readiness Track

Build a sandbox-readiness branch:

- Audit current entitlements.
- Identify features incompatible with sandboxing.
- Decide between:
  - same app with reduced App Store mode
  - separate "midnight-ssh Pro" direct app and "midnight-ssh" App Store app
- Add review-safe demo mode.
- Add App Review notes explaining SSH/server access features.

Apple asks for complete metadata, full review access, and explanations for non-obvious features.

Reference: https://developer.apple.com/app-store/review/guidelines/

## 5. Measurement

After App Store launch:

- Use App Store Connect Analytics for acquisition, conversion, retention, and campaign tracking.
- For direct distribution, add privacy-preserving update/download metrics.
- Track:
  - trial starts
  - first SSH connection success
  - second saved connection
  - dashboard usage
  - conversion to Pro

Apple's App Analytics needs no technical implementation for App Store data.

Reference: https://developer.apple.com/app-store-connect/analytics/

## Recommended Next Implementation Step

Start with `mac-release`, Sparkle, and the entitlement abstraction. Those increase perceived value immediately and do not depend on the pending Apple Developer account.
