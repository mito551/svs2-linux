#!/usr/bin/env bash
# synthv2_setup.sh — sets up Synthesizer V Studio 2 Pro and/or Instrument X in a
# Bottles wine bottle, with URL scheme handlers for in-app authentication.
#
# Usage: ./synthv2_setup.sh [/path/to/SynthV2Installer.exe]
#        (SynthV2 installer path will be prompted if omitted and needed;
#         the Instrument X installer path is always prompted interactively)

set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────

readonly BOTTLE_NAME="SynthV2"
readonly BOTTLES_APP="com.usebottles.bottles"
readonly BOTTLES_DATA="$HOME/.var/app/$BOTTLES_APP/data/bottles"
readonly BOTTLE_PATH="$BOTTLES_DATA/bottles/$BOTTLE_NAME"
readonly BOTTLE_YAML="$BOTTLE_PATH/bottle.yml"
readonly DRIVE_C="$BOTTLE_PATH/drive_c"
readonly RUNNERS_DIR="$BOTTLES_DATA/runners"
readonly WEBVIEW_APP_PATH="$DRIVE_C/Program Files (x86)/Microsoft/EdgeWebView/Application"
readonly WEBVIEW_NEW_VER="92.0.902.73"
readonly WEBVIEW_CAB="Microsoft.WebView2.FixedVersionRuntime.${WEBVIEW_NEW_VER}.x64.cab"
readonly WEBVIEW_CAB_URL="https://github.com/westinyang/WebView2RuntimeArchive/releases/download/${WEBVIEW_NEW_VER}/${WEBVIEW_CAB}"
readonly SYNTHV2_EXE="$DRIVE_C/Program Files/Synthesizer V Studio 2 Pro/synthv-studio.exe"
readonly INSTX_EXE="$DRIVE_C/Program Files/Instrument X/instx.exe"
readonly DESKTOP_DIR="$HOME/.local/share/applications"
readonly HANDLER_SCRIPT="$HOME/.local/bin/synthv2_bottles.sh"
readonly INSTX_HANDLER_SCRIPT="$HOME/.local/bin/instx_bottles.sh"
readonly COMPONENTS_HTML="https://github.com/bottlesdevs/components/tree/main/runners/wine"
readonly COMPONENTS_RAW="https://raw.githubusercontent.com/bottlesdevs/components/main/runners/wine"

TMP_DIR="$(mktemp -d)"

# ── Helpers ────────────────────────────────────────────────────────────────────

die()  { echo "" >&2; echo "✘  ERROR: $*" >&2; exit 1; }
info() { echo ""; echo "── $* ──"; }
ok()   { echo "  ✔  $*"; }

# Wrapper so every bottles-cli call stays DRY.
bcli() { flatpak run --command=bottles-cli "$BOTTLES_APP" "$@"; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Opens Bottles in the background, then blocks until the process exits
# OR the user presses Enter (whichever comes first).
wait_for_bottles_or_enter() {
    flatpak run "$BOTTLES_APP" &
    local pid=$!

    # Give Bottles two seconds to start before we begin polling.
    sleep 2
    kill -0 "$pid" 2>/dev/null || die "Bottles failed to launch"

    echo ""
    echo "  Close Bottles when done, or press Enter to continue."
    echo ""

    while kill -0 "$pid" 2>/dev/null; do
        # Non-blocking read: 1-second timeout.  Returns 0 only if Enter pressed.
        if read -r -t 1 _ 2>/dev/null; then
            break
        fi
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Prompts for an installer path (using $3 as a pre-supplied default if given),
# expands a leading ~, verifies the file exists, and warns if it lives outside
# $HOME (Bottles/Flatpak can only reach $HOME once sandboxed in Step 2).
# Usage: prompt_installer_path OUT_VARNAME "<prompt text>" ["<pre-supplied path>"]
prompt_installer_path() {
    local -n _out="$1"
    local _prompt="$2"
    local _default="${3:-}"

    _out="$_default"
    if [[ -z "$_out" ]]; then
        read -r -p "$_prompt" _out
    fi
    _out="${_out/#\~/$HOME}"   # expand leading ~

    [[ -f "$_out" ]] || die "Installer not found: $_out"

    if [[ "$_out" != "$HOME"/* ]]; then
        echo ""
        echo "  ⚠  Warning: installer is outside \$HOME."
        echo "     After filesystem access is granted, Bottles can only reach paths"
        echo "     under \$HOME.  Consider moving the installer there first."
        echo ""
        read -r -p "  Continue anyway? [y/N] " _confirm
        [[ "${_confirm,,}" == "y" ]] || exit 0
    fi
}

# ── Software selection ─────────────────────────────────────────────────────────

echo ""
echo "  What would you like to install into the SynthV2 bottle?"
echo "    1) Synthesizer V Studio 2 Pro"
echo "    2) Instrument X"
echo "    3) Both"
echo ""
while true; do
    read -r -p "  Choice [1/2/3]: " CHOICE
    case "$CHOICE" in
        1) INSTALL_SYNTHV2=true;  INSTALL_INSTX=false; break ;;
        2) INSTALL_SYNTHV2=false; INSTALL_INSTX=true;  break ;;
        3) INSTALL_SYNTHV2=true;  INSTALL_INSTX=true;  break ;;
        *) echo "  Please enter 1, 2, or 3." ;;
    esac
done

# ── Argument handling ──────────────────────────────────────────────────────────

if [[ "$INSTALL_SYNTHV2" == true ]]; then
    prompt_installer_path SYNTHV2_INSTALLER \
        "Path to Synthesizer V Studio 2 Pro installer (.exe): " "${1:-}"
fi

if [[ "$INSTALL_INSTX" == true ]]; then
    prompt_installer_path INSTX_INSTALLER \
        "Path to Instrument X installer (.exe): "
fi

# ── Pre-flight ─────────────────────────────────────────────────────────────────

info "Pre-flight checks"
command -v flatpak                 >/dev/null || die "flatpak not found"
command -v wget                    >/dev/null || die "wget not found"
command -v tar                     >/dev/null || die "tar not found"
command -v python3                 >/dev/null || die "python3 not found"
command -v cabextract              >/dev/null || die "cabextract not found (install cabextract)"
command -v update-desktop-database >/dev/null || die "update-desktop-database not found (install desktop-file-utils)"
ok "All required tools present"

# ── Step 1: Install Bottles ────────────────────────────────────────────────────

info "Step 1: Bottles"
if flatpak list --app | grep -q "$BOTTLES_APP"; then
    ok "Already installed"
else
    flatpak install -y flathub "$BOTTLES_APP" \
        || die "Failed to install Bottles"
    flatpak list --app | grep -q "$BOTTLES_APP" \
        || die "Bottles not detected after install"
    ok "Installed"
fi

# ── Step 2: Filesystem access ──────────────────────────────────────────────────

info "Step 2: Filesystem access"
if flatpak override --user --show "$BOTTLES_APP" 2>/dev/null | grep -q "home"; then
    ok "Already granted"
else
    flatpak override --user --filesystem=home "$BOTTLES_APP" \
        || die "Failed to grant filesystem=home"
    ok "Granted --filesystem=home"
fi

# ── Step 3: Runner + bottle ────────────────────────────────────────────────────

info "Step 3: Runner and bottle"

if [[ -d "$BOTTLE_PATH" ]]; then
    ok "Bottle '$BOTTLE_NAME' already exists"
else
    # ── 3a: Discover latest kron4ek staging-tkg runner ──────────────────────
    # Scrape GitHub HTML to avoid the unauthenticated API rate limit (60 req/hr).
    echo "  Finding latest kron4ek staging-tkg runner..."
    RUNNER_YML=$(
        wget -qO- "$COMPONENTS_HTML" \
        | grep -oP 'kron4ek-wine-[\d.rc-]+staging-tkg-amd64\.yml' \
        | sort -uV \
        | tail -1
    )
    [[ -n "$RUNNER_YML" ]] \
        || die "No kron4ek-wine-*-staging-tkg-amd64 runner found in component list"

    # The manifest YML filename (without .yml) IS the runner name that
    # bottles-cli new --runner expects — AFTER the post-extract rename.
    RUNNER_NAME="${RUNNER_YML%.yml}"     # kron4ek-wine-X.Y-staging-tkg-amd64
    ok "Latest runner: $RUNNER_NAME"

    # ── 3b: Download runner tarball ─────────────────────────────────────────
    if [[ -f "$RUNNERS_DIR/$RUNNER_NAME/bin/wine" ]]; then
        ok "Runner already present on disk"
    else
        echo "  Fetching manifest..."
        MANIFEST=$(wget -qO- "$COMPONENTS_RAW/$RUNNER_YML") \
            || die "Failed to fetch runner manifest"

        DOWNLOAD_URL=$(echo "$MANIFEST" | grep -E '^\s+url:\s' | awk '{print $2}' | tr -d '\r')
        TARBALL_NAME=$(echo "$MANIFEST" | grep -E '^\s*-?\s*file_name:\s' | awk '{print $NF}' | tr -d '\r')
        EXTRACTED_NAME=$(echo "$MANIFEST" | grep -E '^\s+source:\s' | awk '{print $2}' | tr -d '\r')

        [[ -n "$DOWNLOAD_URL" ]]   || die "Could not parse download URL from runner manifest"
        [[ -n "$TARBALL_NAME" ]]   || die "Could not parse tarball filename from runner manifest"
        [[ -n "$EXTRACTED_NAME" ]] || die "Could not parse extracted name from runner manifest"

        RUNNER_DOWNLOAD="$HOME/Downloads/$TARBALL_NAME"

        if [[ -f "$RUNNER_DOWNLOAD" ]]; then
            ok "Runner tarball already in ~/Downloads, reusing"
        else
            echo "  Downloading $TARBALL_NAME..."
            wget --show-progress -O "$RUNNER_DOWNLOAD" "$DOWNLOAD_URL" \
                || die "Failed to download runner"
        fi

        # ── 3c: Extract + post-extract rename ───────────────────────────────
        # The tarball unpacks to wine-X.Y-staging-tkg-amd64/
        # Bottles expects kron4ek-wine-X.Y-staging-tkg-amd64/ (see manifest Post.rename)
        mkdir -p "$RUNNERS_DIR"
        tar -xf "$RUNNER_DOWNLOAD" -C "$RUNNERS_DIR" \
            || die "Failed to extract runner tarball"

        if [[ "$EXTRACTED_NAME" != "$RUNNER_NAME" ]]; then
            mv "$RUNNERS_DIR/$EXTRACTED_NAME" "$RUNNERS_DIR/$RUNNER_NAME" \
                || die "Failed to apply post-extract rename ($EXTRACTED_NAME → $RUNNER_NAME)"
        fi

        [[ -f "$RUNNERS_DIR/$RUNNER_NAME/bin/wine" ]] \
            || die "Runner verification failed — bin/wine not found"
        ok "Runner extracted and renamed"
    fi

    # ── 3d: Create bottle ────────────────────────────────────────────────────
    echo "  Creating bottle '$BOTTLE_NAME'..."
    # NOTE: --win flag for bottles-cli edit (step 7) was tested against bottles-cli
    # 3.x; if it fails, set the Windows version manually in the Bottles GUI.
    bcli new \
        --bottle-name "$BOTTLE_NAME" \
        --runner      "$RUNNER_NAME" \
        --environment custom \
        || die "bottles-cli new failed"

    echo "  Waiting for bottle to initialize (up to 300s)..."
    timeout 300 bash -c "until [[ -f '$BOTTLE_YAML' ]]; do sleep 2; done" \
        || die "Timed out waiting for bottle.yml (300s)"

    [[ -d "$DRIVE_C/windows" ]] \
        || die "Wine prefix incomplete — drive_c/windows missing"
    ok "Bottle '$BOTTLE_NAME' created"
fi

# ── Step 4: Dependencies via Bottles GUI ──────────────────────────────────────
# Required regardless of which app(s) were selected — both SynthV2 and
# Instrument X need dotnet45 + webview2 in this shared bottle.

info "Step 4: Dependencies (dotnet45 + webview2)"

check_deps() {
    grep -q "dotnet45" "$BOTTLE_YAML" 2>/dev/null \
        && grep -q "webview2"  "$BOTTLE_YAML" 2>/dev/null
}

if check_deps; then
    ok "dotnet45 and webview2 already installed"
else
    while true; do
        echo ""
        echo "  ┌──────────────────────────────────────────────────────────────┐"
        echo "  │  Bottles will open.  Go to:                                  │"
        echo "  │    SynthV2 bottle → Dependencies tab                         │"
        echo "  │  Install both:                                                │"
        echo "  │    • dotnet45                                                 │"
        echo "  │    • webview2                                                 │"
        echo "  └──────────────────────────────────────────────────────────────┘"

        wait_for_bottles_or_enter

        # Re-read bottle.yml fresh after the GUI session.
        if check_deps; then
            ok "dotnet45 and webview2 confirmed in bottle.yml"
            break
        else
            echo "  ⚠  One or both dependencies not detected — please install them and try again."
        fi
    done
fi

# ── Step 5: Install Synthesizer V Studio 2 Pro ────────────────────────────────

info "Step 5a: Synthesizer V Studio 2 Pro"

if [[ "$INSTALL_SYNTHV2" != true ]]; then
    ok "Skipped (not selected)"
elif [[ -f "$SYNTHV2_EXE" ]]; then
    ok "Already installed"
else
    while true; do
        echo ""
        echo "  Launching: $(basename "$SYNTHV2_INSTALLER")"
        echo "  Follow the installation wizard in the wine window."
        echo ""

        bcli run -b "$BOTTLE_NAME" -e "$SYNTHV2_INSTALLER" &
        INSTALLER_PID=$!

        sleep 2
        kill -0 "$INSTALLER_PID" 2>/dev/null \
            || die "Installer process failed to start"

        echo "  Press Enter here once installation is complete."
        while kill -0 "$INSTALLER_PID" 2>/dev/null; do
            if read -r -t 1 _ 2>/dev/null; then
                break
            fi
        done

        kill "$INSTALLER_PID" 2>/dev/null || true
        wait "$INSTALLER_PID" 2>/dev/null || true

        if [[ -f "$SYNTHV2_EXE" ]]; then
            ok "synthv-studio.exe detected"
            break
        else
            echo "  ⚠  synthv-studio.exe not found at expected path."
            echo "     Expected: $SYNTHV2_EXE"
            echo "     Please complete the installer and try again."
        fi
    done
fi

# ── Step 5b: Install Instrument X ───────────────────────────────────────────────

info "Step 5b: Instrument X"

if [[ "$INSTALL_INSTX" != true ]]; then
    ok "Skipped (not selected)"
elif [[ -f "$INSTX_EXE" ]]; then
    ok "Already installed"
else
    while true; do
        echo ""
        echo "  Launching: $(basename "$INSTX_INSTALLER")"
        echo "  Follow the installation wizard in the wine window."
        echo ""

        bcli run -b "$BOTTLE_NAME" -e "$INSTX_INSTALLER" &
        INSTALLER_PID=$!

        sleep 2
        kill -0 "$INSTALLER_PID" 2>/dev/null \
            || die "Installer process failed to start"

        echo "  Press Enter here once installation is complete."
        while kill -0 "$INSTALLER_PID" 2>/dev/null; do
            if read -r -t 1 _ 2>/dev/null; then
                break
            fi
        done

        kill "$INSTALLER_PID" 2>/dev/null || true
        wait "$INSTALLER_PID" 2>/dev/null || true

        if [[ -f "$INSTX_EXE" ]]; then
            ok "instx.exe detected"
            break
        else
            echo "  ⚠  instx.exe not found at expected path."
            echo "     Expected: $INSTX_EXE"
            echo "     Please complete the installer and try again."
        fi
    done
fi

# ── Step 6: Downgrade WebView2 → 92.0.902.73 ──────────────────────────────────
# Required regardless of which app(s) were selected (shared bottle).

info "Step 6: WebView2 downgrade → $WEBVIEW_NEW_VER"

# Detect whichever version directory Bottles actually installed (e.g. 146.x.x.x),
# excluding the SetupMetrics folder which also lives here.
WEBVIEW_INSTALLED_VER=$(find "$WEBVIEW_APP_PATH" -maxdepth 1 -mindepth 1 -type d \
    ! -name "SetupMetrics" -printf '%f\n' | head -1)
[[ -n "$WEBVIEW_INSTALLED_VER" ]] \
    || die "Could not detect installed WebView2 version under $WEBVIEW_APP_PATH"

WEBVIEW_TARGET="$WEBVIEW_APP_PATH/$WEBVIEW_INSTALLED_VER"

# Read the actual version from the .manifest file inside the WebView2 directory.
WEBVIEW_MANIFEST=$(find "$WEBVIEW_TARGET" -maxdepth 1 -name "*.manifest" -printf '%f\n' | head -1)
WEBVIEW_ACTUAL_VER="${WEBVIEW_MANIFEST%.manifest}"

if [[ "$WEBVIEW_ACTUAL_VER" == "$WEBVIEW_NEW_VER" ]]; then
    ok "Already at $WEBVIEW_NEW_VER"
else
    CAB_HOST="$HOME/Downloads/$WEBVIEW_CAB"
    CAB_EXTRACT_DIR="$DRIVE_C/webview2_extract"

    if [[ -f "$CAB_HOST" ]]; then
        ok "CAB already in ~/Downloads, reusing"
    else
        echo "  Downloading $WEBVIEW_CAB..."
        wget --show-progress -O "$CAB_HOST" "$WEBVIEW_CAB_URL" \
            || die "Failed to download WebView2 cab"
    fi

    mkdir -p "$CAB_EXTRACT_DIR"

    echo "  Extracting CAB on host..."
    cabextract -d "$CAB_EXTRACT_DIR" "$CAB_HOST" \
        || die "cabextract failed"

    EXTRACTED_WEBVIEW="$CAB_EXTRACT_DIR/Microsoft.WebView2.FixedVersionRuntime.${WEBVIEW_NEW_VER}.x64"
    [[ -d "$EXTRACTED_WEBVIEW" ]] \
        || die "Expected extraction dir not found: $EXTRACTED_WEBVIEW"

    # Clear the existing versioned directory and replace its contents with the
    # downgraded build, preserving the directory name Bottles expects (146.x etc).
    rm -rf "$WEBVIEW_TARGET"
    mkdir -p "$WEBVIEW_TARGET"
    cp -r "$EXTRACTED_WEBVIEW/." "$WEBVIEW_TARGET/" \
        || die "Failed to copy extracted files to $WEBVIEW_TARGET"

    [[ -f "$WEBVIEW_TARGET/msedgewebview2.exe" ]] \
        || die "Post-copy verification failed"

    rm -rf "$CAB_EXTRACT_DIR"

    ok "WebView2 downgraded to $WEBVIEW_NEW_VER (in $WEBVIEW_INSTALLED_VER/)"
fi

# ── Step 7: URL handler script(s) ──────────────────────────────────────────────

info "Step 7: URL handler script(s)"

mkdir -p "$(dirname "$HANDLER_SCRIPT")"

if [[ "$INSTALL_SYNTHV2" == true ]]; then
    # Single-quoted heredoc — $1 must remain a literal variable in the output file.
    cat > "$HANDLER_SCRIPT" << 'HANDLER'
#!/usr/bin/env bash
flatpak run --command=bottles-cli com.usebottles.bottles shell -b SynthV2 \
    -i "\"C:\\\\Program Files\\\\Synthesizer V Studio 2 Pro\\\\synthv-studio.exe\" \"$1\""
HANDLER
    chmod +x "$HANDLER_SCRIPT"
    [[ -x "$HANDLER_SCRIPT" ]] || die "SynthV2 handler script not executable after creation"
    ok "$HANDLER_SCRIPT"
fi

if [[ "$INSTALL_INSTX" == true ]]; then
    cat > "$INSTX_HANDLER_SCRIPT" << 'HANDLER'
#!/usr/bin/env bash
flatpak run --command=bottles-cli com.usebottles.bottles shell -b SynthV2 \
    -i "\"C:\\\\Program Files\\\\Instrument X\\\\instx.exe\" \"$1\""
HANDLER
    chmod +x "$INSTX_HANDLER_SCRIPT"
    [[ -x "$INSTX_HANDLER_SCRIPT" ]] || die "Instrument X handler script not executable after creation"
    ok "$INSTX_HANDLER_SCRIPT"
fi

# ── Step 8: Desktop entry(ies) ─────────────────────────────────────────────────

info "Step 8: Desktop entry(ies)"

mkdir -p "$DESKTOP_DIR"

if [[ "$INSTALL_SYNTHV2" == true ]]; then
    DESKTOP_FILE="$DESKTOP_DIR/svstudio2-url-handler.desktop"
    # Double-quoted heredoc — $HANDLER_SCRIPT expands to the absolute path.
    cat > "$DESKTOP_FILE" << DESKTOP
[Desktop Entry]
Type=Application
Name=SVStudio2 URL Handler
Exec=$HANDLER_SCRIPT %u
MimeType=x-scheme-handler/dreamtonics-svstudio2
NoDisplay=true
Terminal=false
DESKTOP
    [[ -f "$DESKTOP_FILE" ]] || die "SynthV2 desktop entry not created"
    ok "$DESKTOP_FILE"
fi

if [[ "$INSTALL_INSTX" == true ]]; then
    INSTX_DESKTOP_FILE="$DESKTOP_DIR/instx-url-handler.desktop"
    cat > "$INSTX_DESKTOP_FILE" << DESKTOP
[Desktop Entry]
Type=Application
Name=Instrument X URL Handler
Exec=$INSTX_HANDLER_SCRIPT %u
MimeType=x-scheme-handler/dreamtonics-instx
NoDisplay=true
Terminal=false
DESKTOP
    [[ -f "$INSTX_DESKTOP_FILE" ]] || die "Instrument X desktop entry not created"
    ok "$INSTX_DESKTOP_FILE"
fi

# ── Step 9: Register MIME handler ─────────────────────────────────────────────

info "Step 9: update-desktop-database"
update-desktop-database "$DESKTOP_DIR" \
    || die "update-desktop-database failed"
ok "MIME database updated"

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "  ╔═════════════════════════════════════════════════════════════════╗"
echo "  ║  Setup complete.                                                ║"
echo "  ║                                                                 ║"
echo "  ║  Final steps (manual):                                          ║"
echo "  ║    1. Launch Bottles                                            ║"
if [[ "$INSTALL_SYNTHV2" == true ]]; then
echo "  ║    2. In the SynthV2 Bottles settings, set Windows version to 7 ║"
fi
echo "  ║    3. Launch Synthesizer V Studio 2 Pro or Instrument X   	  ║"
echo "  ║    4. Click Log In                                              ║"
echo "  ║    5. In the browser — try the desktop handler first           ║"
echo "  ║       If that fails, point it to the script directly, located: ║"
if [[ "$INSTALL_SYNTHV2" == true ]]; then
echo "  ║         SynthV2: $HANDLER_SCRIPT"
fi
if [[ "$INSTALL_INSTX" == true ]]; then
echo "  ║         InstX: $INSTX_HANDLER_SCRIPT "
fi
echo "  ╚═════════════════════════════════════════════════════════════════╝"
echo ""
