# Building VoiceInk

## Requirements

- macOS 14.4 or later
- Xcode with Command Line Tools and the Metal Toolchain component
- Git
- CMake 3.28 or later

Install the Metal Toolchain after installing Xcode:

```bash
xcodebuild -downloadComponent MetalToolchain
```

With Homebrew, CMake can be installed using `brew install cmake`.

## Local Build

```bash
make local
open dist/my-voice.app
```

`make local` prepares the pinned `whisper.cpp` revision recorded in the Makefile and its `whisper.xcframework` under `~/VoiceInk-Dependencies`, builds Release in `.local-build`, and copies the result to `dist/my-voice.app`. It refuses to overwrite a dependency checkout with local changes or an unexpected Git origin.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the only available Apple Development identity or falls back to ad-hoc signing when none or multiple are found.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds use an independent bundle identifier, Keychain service, Application Support directory, and output name. They do not include iCloud dictionary sync, official VoiceInk automatic updates, or commercial license network calls. Apple Development signing gives rebuilt apps a stable designated requirement; ad-hoc builds may require macOS permissions again after rebuilding.

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `dist/my-voice.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove the managed `~/VoiceInk-Dependencies/whisper.cpp` checkout and framework
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- If `make check` reports a missing Metal Toolchain, run `xcodebuild -downloadComponent MetalToolchain`.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- If Xcode shows an Apple Development certificate but `security find-identity -v -p codesigning` reports no valid identities, install the matching Apple WWDR intermediate certificate from the [Apple PKI page](https://www.apple.com/certificateauthority/). Apple Development certificates currently use Worldwide Developer Relations G3.
- For additional help, open a [GitHub issue](https://github.com/Beingpax/VoiceInk/issues).
