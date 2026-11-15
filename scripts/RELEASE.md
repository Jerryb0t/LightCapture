# Local release preparation

Normal `./build.sh` remains a local ad-hoc build. It is not notarized and must not
be described as ready for unrestricted download/install.

For an owner who already has a valid Developer ID Application identity:

```sh
BUILD_MODE=release SIGN_IDENTITY='Developer ID Application: Your Existing Identity (TEAM)' APP_OUTPUT=/tmp/LightCapture-release.app ./build.sh
```

The preflight requires an exact valid existing identity and available notarytool/
stapler before creating build output. It never creates identities, enrolls in an
Apple program, saves passwords, exports keys, or uploads files. Nested Sparkle
code is signed inside out with the same identity, hardened runtime and secure
timestamps, preserving Downloader's existing entitlements as Sparkle documents.
The main app has only the audio-input entitlement needed for microphone use.
Library validation is not disabled. Signing does not use `--deep`.

A successful release build is **signed only**, not notarized or Gatekeeper
approved. The owner must complete Apple's notarization workflow using their
already-authorized account and staple the accepted ticket. No submission command
is run by these scripts. After that, explicitly check:

```sh
python3 scripts/release-signing.py verify-notarized /tmp/LightCapture-release.app
```

This checks the strict signature, stapled ticket and current Gatekeeper policy;
it does not launch the app or change policy. A failure blocks distribution.
Archive only the final stapled app, then use the owner's dedicated Sparkle
signing account to sign the update archive and feed. Never modify bytes after
signing. Publish the verified archive before its signed feed. Do not publish a
fixture, a private key, or a failed candidate.

Tests: `python3 Tests/ReleaseSigningTests.py` uses only synthetic signing plans;
it does not exercise an actual Developer ID identity or notarization service.

Official references:
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- https://sparkle-project.org/documentation/sandboxing/#code-signing
