# Packaging

`./scripts/build-app.sh release` produces the local ad-hoc signed
`build/Skriv.app`. The app uses system frameworks and ships no external editor
runtime, network updater, or third-party package.

The ad-hoc signature is suitable for local development. To distribute outside
this machine, use an Apple Developer ID Application signing identity, enable the
hardened runtime, notarize, and staple the result. The commands below are an
operator checklist; they do not run as part of the local build:

```sh
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: YOUR ORGANIZATION (TEAMID)" build/Skriv.app
codesign --verify --strict --verbose=2 build/Skriv.app
ditto -c -k --keepParent build/Skriv.app build/Skriv-notarization.zip
xcrun notarytool submit build/Skriv-notarization.zip \
  --keychain-profile YOUR_NOTARY_PROFILE --wait
xcrun stapler staple build/Skriv.app
xcrun stapler validate build/Skriv.app
spctl --assess --type execute --verbose=2 build/Skriv.app
ditto -c -k --keepParent build/Skriv.app build/Skriv.zip
```

Configure signing and notarization credentials in Keychain before using those
commands. Keep credentials out of the repository. The final ZIP must be created
after stapling. Signing/notarization and downloaded-app Gatekeeper verification
remain release checks that require the distributor's identity.
See Apple's [distribution signing guide](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
and [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Before a public release, verify native save/open dialogs, failed saves,
unsaved-change cancel/discard/quit, Dock/launcher reopening, active line-number emphasis,
accessibility, marked-text input, display/Space behavior, and startup/memory
baselines on the supported macOS versions. Verify opening, saving, and reloading
`~/.config/skriv/config.skriv`, including invalid settings and rejection of the removed `global-shortcut` key.
