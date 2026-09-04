# SynthV2 Bottles Setup

Sets up Synthesizer V Studio 2 Pro and/or Instrument X in a dedicated Bottles wine bottle on Linux, including the WebView2 downgrade the login flow requires and a URL scheme handler for browser-based authentication.

## What the script does

1. Installs Bottles (Flatpak) if not already present.
2. Grants Bottles filesystem access under `$HOME` via `flatpak override`.
3. Finds the latest `kron4ek-*-staging-tkg` wine runner, downloads it, and creates a bottle named `SynthV2`.
4. Opens Bottles so you can install the `dotnet45` and `webview2` dependencies through the GUI. The script polls `bottle.yml` and confirms both are present before continuing.
5. Runs your Synthesizer V Studio 2 Pro and/or Instrument X installer inside the bottle. You complete the install wizard; the script confirms `synthv-studio.exe` exists afterward.
6. Downloads the WebView2 92.0.902.73 fixed-version runtime, extracts it with `cabextract`, and replaces the bottle's default WebView2 version with it.
7. Writes a handler script and a `.desktop` file that registers the `dreamtonics-svstudio2://` URL scheme, so the app's browser-based login can hand control back to it.
8. Registers the new desktop entry with `update-desktop-database`.

The final step, logging in, is up to you. Launch Synthesizer V Studio 2 Pro and/or Instrument X, click Log In, and complete authentication in the browser. If the desktop handler doesn't pick up the redirect, point it to the script instead, although in my testing on Fedora w/ GNOME and CachyOS w/ KDE that wasn't necessary.

## Requirements

Install these with your distro's package manager before running:

- `flatpak`
- `wget`
- `tar`
- `python3`
- `update-desktop-database` (part of `desktop-file-utils` on most distros)
- `cabextract`

You'll also need the Synthesizer V Studio 2 Pro and/or Instrument X installer `.exe` downloaded ahead of time.

## Usage

```bash
./synthv2_setup.sh /path/to/SynthV2Installer.exe
```

Without the argument the script prompts for the path.

If the installer lives outside `$HOME`, the script warns you: once filesystem access is scoped to `$HOME` in step 2, Bottles can no longer reach files elsewhere. Move the installer under `$HOME` first, or confirm you understand the risk when prompted.

## What's automated versus manual

The script handles bottle creation, runner selection, dependency detection, and file placement without intervention. Three steps need you at the keyboard:

- **Dependency installation** (step 4): Bottles' CLI has no command for installing dependencies like `dotnet45`. The script opens the Bottles GUI, waits for you to install both dependencies or close the window, then checks `bottle.yml` to confirm they landed. If either is missing, it asks you to try again.
- **Synthesizer V installation** (step 5): same pattern. The installer runs inside the bottle; you click through the wizard; the script verifies the resulting executable exists.
- **Login** (final step): opening the browser and authenticating is entirely on you. The script sets up the handler that lets the browser redirect back into the app, but can't complete the login itself.

All the other steps include a completion check before the script moves on. If a step fails, the script stops and tells you which check failed, rather than continuing on a broken bottle.

## Design notes

**Idempotency.** Each major step checks whether its target already exists before doing anything: bottle directory, dependency list in `bottle.yml`, `synthv-studio.exe`, the target WebView2 version. Run the script twice and the second run skips everything already done.

**No hardcoded package manager.** The script checks for required tools with `command -v` and stops with a clear error if one is missing. It doesn't call `apt`, `pacman`, or `dnf` on your behalf. Install the missing tool through your own distro's package manager and rerun.

**Desktop entry location.** The `.desktop` file goes to `~/.local/share/applications`, the standard per-user location defined by the freedesktop.org XDG spec. No `sudo` required, and any desktop environment following the spec will pick it up.

## Known limitations

- The `bottles-cli edit --win win7` call (step 7) does not work, otherwise the step of changing the windows version could have been automated. Win7 setting is required for WebView2 windows to render in SVS2 - this problem does not exist in Instrument X.
- Runner discovery scrapes the GitHub component listing page rather than calling the API, to avoid the unauthenticated API's low rate limit. If GitHub changes that page's markup, the scrape may need updating.
- The script assumes the westinyang WebView2 archive continues shipping `.cab` format releases at the URL pattern it currently uses. If the repository goes down, the script won't be able to downgrade WebView2

## Files created

| Path | Purpose |
|---|---|
| `~/.var/app/com.usebottles.bottles/data/bottles/bottles/SynthV2/` | The bottle itself |
| `~/.var/app/com.usebottles.bottles/data/bottles/runners/kron4ek-wine-*-staging-tkg-amd64/` | Downloaded wine runner |
| `~/.local/bin/synthv2_bottles.sh` | URL handler script |
| `~/.local/share/applications/svstudio2-url-handler.desktop` | Desktop entry registering the URL scheme |
