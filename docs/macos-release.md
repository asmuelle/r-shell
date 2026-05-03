# macOS Release Setup

## Local Release Command

Use this while the Apple Developer account is pending:

```bash
just mac-release
```

The command performs a clean native macOS build, packages a DMG, writes a SHA-256 checksum, and creates release notes under:

```text
r-shell-macos/build/release/
```

If `APPLE_SIGNING_IDENTITY` is not set, the release is ad-hoc signed and intended only for internal testing.

After the Apple Developer account is approved and signing credentials are installed:

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" just mac-release true
```

The `true` argument runs notarization through `just mac-notarize`.

## Sparkle Updates

Sparkle is linked through the XcodeGen project. The app starts the updater only when `SUPublicEDKey` is configured in `RShellApp/Info.plist`.

Generate the EdDSA key once:

```bash
just mac-gen
just mac-ci-build
just mac-sparkle-keygen
```

Add the printed public key to `SUPublicEDKey` and keep the private key safe. Sparkle stores the private key in the login Keychain by default.

To generate an appcast from a release folder:

```bash
just mac-sparkle-appcast r-shell-macos/build/release/<release-folder>
```

For unsigned local testing with a static URL, set `MAC_RELEASE_BASE_URL` before `just mac-release`; the release script writes a minimal `appcast.xml` next to the DMG. Production releases should use Sparkle's `generate_appcast` tool so update archives are signed.

The `macOS Release` workflow builds, signs, packages, notarizes, staples, and uploads `midnight-ssh.dmg`.

Configure these GitHub Actions secrets before running it:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` certificate. |
| `MACOS_CERTIFICATE_PASSWORD` | Password for the `.p12` certificate. |
| `MACOS_CI_KEYCHAIN_PASSWORD` | Temporary keychain password used only on the CI runner. |
| `APPLE_SIGNING_IDENTITY` | Full Developer ID Application signing identity name. |
| `APPLE_ID` | Apple ID used for notarization. |
| `APPLE_TEAM_ID` | Apple Developer Team ID. |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for `xcrun notarytool`. |

To create the base64 certificate value locally:

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

The workflow intentionally fails if any signing or notarization secret is missing. Local development builds should continue to use:

```bash
just mac-build
just mac-run
```

Before cutting a tag, run:

```bash
just check
just test-rust
pnpm --prefix r-shell-tauri build
xcodebuild -project r-shell-macos/R-Shell.xcodeproj \
  -scheme RShellApp \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/rshell-dd \
  CODE_SIGNING_ALLOWED=NO \
  build
```
