# Distributing Enigma

Hardened Runtime is enabled for both Debug and Release in the Enigma app target.
The shared Enigma scheme archives Release. Build a **new archive** after pulling
this change; an existing archive still contains its original signing settings.
In Xcode, select the Enigma scheme, choose **Product → Archive**, then distribute
the new archive from Organizer using the appropriate distribution identity.

`AI-Spotlight/Resources/Enigma.entitlements` grants Location access for the existing
nearby/weather feature. The existing location usage description and user consent
flow still apply. No JIT, unsigned executable memory, DYLD, or library-validation
exceptions are enabled, and App Sandbox is not enabled by this change.

The embedded llama framework must be signed with the same team as Enigma; Xcode
signs the embedded copy. Downloaded llama-server and the installed Codex CLI run
as separate executables, rather than loading their libraries into Enigma's process.
Hardened Runtime does not replace their existing download-integrity or launch checks.

For a signed archive, inspect the app with `codesign -dvv` and confirm its flags
include `runtime`. Use `codesign --verify --deep --strict --verbose=2` to validate
the app and embedded framework signatures. Inspect entitlements with
`codesign -d --entitlements -`; a distribution export must not include
`com.apple.security.get-task-allow`. Developer ID signing and notarization remain
separate distribution steps; successful unit tests are not proof of notarization.

Before shipping, use the signed app to check a local model, ChatGPT sign-in,
screenshot/selection capture, and a nearby/weather question. Automated tests cover
mocked permission paths but cannot grant or verify real macOS user consent.

References: [Apple Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime),
[Location entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.location),
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
