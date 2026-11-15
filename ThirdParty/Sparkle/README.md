# Sparkle

LightCapture uses Sparkle 2.10.1 from the official project:
https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1

The build downloads the official archive, verifies SHA-256
`1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`,
then embeds the signed framework. Binary tools and framework are cached under
`build/vendor/`, not committed. See LICENSE for Sparkle and bundled components.

The distribution uses bundle identifier `local.jerry.lightcapture.autolongpreview`
to preserve existing user settings. Builds with another identifier are not
compatible with the distribution's in-app update archives.

Update archives and the appcast must be signed with the publisher's Ed25519 key.
Only its public key is embedded in the application. Private release keys are
not included in source or archives. Ad-hoc code signing is not Apple Developer ID
signing or notarization; macOS can require approval or refuse an update. The app
never disables Gatekeeper or strips quarantine to bypass this.
