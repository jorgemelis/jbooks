# jbooks

Multi-device EPUB/PDF reader (Mac Catalyst + iOS) built on the
[Readium](https://github.com/readium/swift-toolkit) toolkit.

## Status

- **Mac Catalyst** is the primary client.
- Working: library list from a OneDrive folder → open EPUB with Readium →
  render → live font-size controls.

## Project generation

The Xcode project is **generated** from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is the source
of truth and the `.xcodeproj` is git-ignored. After cloning, or after
adding/renaming any file under `Sources/`, regenerate it:

```sh
xcodegen generate
```

## Build & run (Mac Catalyst)

Signing uses your own Apple Developer team — pass it via `DEVELOPMENT_TEAM`
(or set it in Xcode's signing settings):

```sh
xcodebuild build \
  -project jbooks.xcodeproj -scheme jbooks -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID

open build/Build/Products/Debug-maccatalyst/jbooks.app
```

> Note: the library folder is currently hardcoded in `Sources/Library.swift`
> to the author's OneDrive path — change it to your own EPUB folder.
