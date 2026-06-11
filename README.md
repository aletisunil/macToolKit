# macToolKit

Menu bar toolkit for macOS 26+ (Apple Silicon). Four tools, individually
toggled from the wrench menu bar icon. Optional dock icon ("Show in Dock").

## Features

| Feature | Permission | Notes |
|---|---|---|
| Finder right-click: New File + Copy Path | Enable extension | Editable New File templates (starter set: .txt .py .md .js) |
| Color temperature (f.lux style) | none | Manual slider or sunset/sunrise auto mode |
| Rewritely — trigger-word AI rewrite | Accessibility | Apple Intelligence on-device; default triggers `;;fix` `;;tight` `;;prof` |
| Scroll Reverser | Accessibility | Trackpad/mouse and vertical/horizontal independently |

## Install

### Homebrew (recommended)

```sh
brew install --cask aletisunil/tap/mactoolkit
```

Or tap once, then use the short name:

```sh
brew tap aletisunil/tap
brew install --cask mactoolkit
```

Upgrade:

```sh
brew upgrade --cask mactoolkit
```

Uninstall:

```sh
brew uninstall --cask mactoolkit        # remove the app
brew uninstall --zap --cask mactoolkit  # also remove settings/caches
```

### Manual

Download the latest `macToolKit.dmg` from
[Releases](https://github.com/aletisunil/macToolKit/releases), open it and
drag macToolKit to Applications. The app is Developer ID signed and
notarized — no Gatekeeper warnings.

After installing either way, see [First-run setup](#first-run-setup) for the
Finder-extension and Accessibility permissions each tool needs.

## Build

```sh
brew install xcodegen   # once
xcodegen generate
xcodebuild -project macToolKit.xcodeproj -scheme macToolKit -configuration Debug build
```

Signing uses the local "Apple Development" identity (team 5432YAY2UX, set in
project.yml). The app group is team-prefixed (`5432YAY2UX.…`) so no
provisioning profile is needed.

## Releasing

Push a version tag and CI builds, signs, notarizes and publishes a `.dmg` +
`.zip` to GitHub Releases (see `.github/workflows/release.yml`):

```sh
git tag v1.0.0
git push origin v1.0.0
```

Local release build: `Scripts/release.sh 1.0.0` (needs the Developer ID
certificate and a saved `notarytool` keychain profile named `macToolKit`).

## First-run setup

1. **Finder extension** — System Settings → General → Login Items & Extensions
   → Finder → enable "macToolKit Finder Tools". (Settings → Finder tab has a
   shortcut button.)
2. **Accessibility** — needed only for Scroll Reverser and Rewritely; grant
   from Settings → General when prompted.
3. **Rewritely** — requires Apple Intelligence enabled in System Settings.
4. Auto color temperature can use Location (optional) or fixed times.

## How Rewritely works

Type a trigger word at the very end of any text field (e.g.
`fix this sentnce pls ;;fix`). The app reads the field via Accessibility,
strips the trigger, runs your per-trigger prompt (`{{text}}` = the field text)
through the on-device model, and replaces the text in place. Fields without a
settable AX value (some Electron/web views) use a select-all + paste fallback.

## Architecture notes

- `macToolKit/` — main app (non-sandboxed). `Features/` one folder per tool.
- `FinderTools/` — sandboxed FinderSync extension; it cannot write files, so
  New File requests are sent to the main app via `mactoolkit://` URLs.
- Gamma tables (`CGSetDisplayTransferByTable`) are reset by macOS on wake and
  display changes; `ColorTemperatureController` reapplies automatically and
  `CGDisplayRestoreColorSyncSettings()` restores on disable/quit.
- Event taps run on the main run loop; both auto-recover from
  `tapDisabledByTimeout`.
