#!/usr/bin/env bash
# =====================================================================================================================
#  City Ground Zero - the one script. Sets everything up (asking before it installs anything), repairs what is broken,
#  then runs the Live Operations Control Room with its partner layers.
#
#    ./run_control_room.sh                 set up / repair if needed, then run the control room
#    ./run_control_room.sh --dashboard     ... and the web dashboard (http://127.0.0.1:8870/)   [--dashboard=PORT, --no-browser]
#    ./run_control_room.sh --scenario T01  run one Test Book scenario, then close (what scenarios/*.sh do)
#    ./run_control_room.sh --setup         set up / repair only           --check   report only, change nothing
#    ./run_control_room.sh --tests         run the twin's test suite      --editor  open the Godot editor on the twin
#    ./run_control_room.sh --yes           do not ask before installing  --help    this text
#
#  Linux (x86_64, arm64), macOS (Apple silicon, Intel) and Windows (Git Bash / MSYS2). Everything it installs goes under
#  twin/.runtime/ (Godot 4.7.2 from godotengine's GitHub releases, verified with their SHA-512 sums; SUMO 1.25.0 and the
#  Python packages from PyPI into a private Python environment); nothing is installed system-wide unless you agree to it.
# =====================================================================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TWIN="$ROOT/twin"
SRC="$TWIN/src"
RUNTIME="$TWIN/.runtime"
CONF="$TWIN/twin.conf"
RUN_DIR="$RUNTIME/run"
SETUP_LOG="$RUNTIME/setup.log"
GODOT_VERSION="4.7.2"
SUMO_VERSION="1.25.0"
PYTHON_PACKAGES=("eclipse-sumo==$SUMO_VERSION" "cryptography>=42")
UV_PYTHON="3.12"

# ------------------------------------------------------------------------------------------------- options
mode="run"; scenario=""; assume_yes=0; dashboard=0; dashboard_open=1; dashboard_port="${CITY_DASHBOARD_PORT:-8870}"
forwarded=()
[[ "${CITY_DASHBOARD:-0}" == "1" ]] && dashboard=1
while (($#)); do
    case "$1" in
        --setup) mode="setup" ;;
        --check) mode="check" ;;
        --tests) mode="tests" ;;
        --editor) mode="editor" ;;
        --scenario) mode="scenario"; scenario="${2:-}"; shift ;;
        --scenario=*) mode="scenario"; scenario="${1#--scenario=}" ;;
        --yes|-y) assume_yes=1 ;;
        --dashboard) dashboard=1 ;;
        --dashboard=*) dashboard=1; dashboard_port="${1#--dashboard=}" ;;
        --no-browser) dashboard_open=0 ;;
        --help|-h) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^#  \{0,1\}//'; exit 0 ;;
        *) forwarded+=("$1") ;;
    esac
    shift
done

# ------------------------------------------------------------------------------------------------- output
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'; else B=""; G=""; R=""; Y=""; C=""; D=""; N=""; fi
mkdir -p "$RUNTIME" "$RUN_DIR" 2>/dev/null
note() { printf '%s\n' "$(date '+%F %T')  $*" >>"$SETUP_LOG" 2>/dev/null; }
step() { printf '\n%s▶ %s%s\n' "$B" "$*" "$N"; note "STEP $*"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; note "OK   $*"; }
bad()  { printf '  %s✖%s %s\n' "$R" "$N" "$*"; note "FAIL $*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; note "WARN $*"; }
info() { printf '  %s·%s %s\n' "$C" "$N" "$*"; note "INFO $*"; }
die()  { printf '\n%s✖ %s%s\n' "$R" "$*" "$N" >&2; note "DIE  $*"; printf '  The setup transcript is in %s\n' "$SETUP_LOG" >&2; exit 1; }
ask() {
    # ask "question" -> 0 for yes. --yes answers yes; without a terminal the answer is no (say --yes to allow it).
    if ((assume_yes)); then info "$1 → yes (--yes)"; return 0; fi
    if [[ ! -t 0 ]]; then warn "$1 → no (no terminal to ask; run again with --yes to allow it)"; DECLINED=1; return 1; fi
    local reply; read -r -p "  ${Y}?${N} $1 [Y/n] " reply
    if [[ -z "$reply" || "$reply" =~ ^[YyOo] ]]; then return 0; fi
    DECLINED=1; return 1
}
DECLINED=0

# ------------------------------------------------------------------------------------------------- platform
detect_platform() {
    case "$(uname -s)" in
        Linux*) OS="linux" ;;
        Darwin*) OS="macos" ;;
        MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
        *) die "Unsupported operating system: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64|AMD64) ARCH="x86_64" ;;
        aarch64|arm64|ARM64) ARCH="arm64" ;;
        *) die "Unsupported processor: $(uname -m)" ;;
    esac
    EXE=""; [[ "$OS" == "windows" ]] && EXE=".exe"
    VENV="$RUNTIME/venv"
    if [[ "$OS" == "windows" ]]; then VENV_PY="$VENV/Scripts/python.exe"; else VENV_PY="$VENV/bin/python"; fi
    GODOT_DIR="$RUNTIME/godot"
    case "$OS-$ARCH" in
        linux-x86_64) GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"; GODOT_BIN="$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_linux.x86_64" ;;
        linux-arm64) GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_linux.arm64.zip"; GODOT_BIN="$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_linux.arm64" ;;
        macos-*) GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_macos.universal.zip"; GODOT_BIN="$GODOT_DIR/Godot.app/Contents/MacOS/Godot" ;;
        windows-x86_64) GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_win64.exe.zip"; GODOT_BIN="$GODOT_DIR/Godot_v${GODOT_VERSION}-stable_win64_console.exe" ;;
        *) die "No official Godot $GODOT_VERSION build for $OS on $ARCH" ;;
    esac
    GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable"
    case "$OS-$ARCH" in
        linux-x86_64) UV_ASSET="uv-x86_64-unknown-linux-gnu.tar.gz" ;;
        linux-arm64) UV_ASSET="uv-aarch64-unknown-linux-gnu.tar.gz" ;;
        macos-arm64) UV_ASSET="uv-aarch64-apple-darwin.tar.gz" ;;
        macos-x86_64) UV_ASSET="uv-x86_64-apple-darwin.tar.gz" ;;
        windows-x86_64) UV_ASSET="uv-x86_64-pc-windows-msvc.zip" ;;
    esac
    PKG=""
    for candidate in apt-get dnf pacman zypper brew winget; do
        command -v "$candidate" >/dev/null 2>&1 && { PKG="$candidate"; break; }
    done
}

download() { # download URL FILE
    if command -v curl >/dev/null 2>&1; then
        local progress=(-sS); [[ -t 2 ]] && progress=(--progress-bar)
        curl -fL --retry 4 --retry-delay 2 --connect-timeout 20 "${progress[@]}" -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        local progress=(-q); [[ -t 2 ]] && progress=(-q --show-progress)
        wget "${progress[@]}" --tries=4 -O "$2" "$1"
    else
        return 9
    fi
}

sha_of() { # sha_of 256|512 FILE
    if command -v "sha${1}sum" >/dev/null 2>&1; then "sha${1}sum" "$2" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a "$1" "$2" | cut -d' ' -f1
    elif [[ -x "$VENV_PY" ]]; then "$VENV_PY" -c "import hashlib,sys;print(hashlib.sha$1(open(sys.argv[1],'rb').read()).hexdigest())" "$2"
    else python3 -c "import hashlib,sys;print(hashlib.sha$1(open(sys.argv[1],'rb').read()).hexdigest())" "$2"; fi
}

# ------------------------------------------------------------------------------------------------- 1. tools
check_tools() {
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then ok "downloader: $(command -v curl || command -v wget)"; return 0; fi
    bad "neither curl nor wget is installed (needed to download Godot and SUMO)"; return 1
}
install_tools() {
    case "$PKG" in
        apt-get) ask "Install curl with 'sudo apt-get install -y curl'?" && sudo apt-get install -y curl ;;
        dnf) ask "Install curl with 'sudo dnf install -y curl'?" && sudo dnf install -y curl ;;
        pacman) ask "Install curl with 'sudo pacman -S --noconfirm curl'?" && sudo pacman -S --noconfirm curl ;;
        zypper) ask "Install curl with 'sudo zypper install -y curl'?" && sudo zypper install -y curl ;;
        brew) ask "Install curl with 'brew install curl'?" && brew install curl ;;
        *) false ;;
    esac
}

# ------------------------------------------------------------------------------------------------- 2. python + SUMO
sumo_home() { "$VENV_PY" -c "import sumo,sys;print(sumo.SUMO_HOME)" 2>/dev/null; }
check_python() {
    PY_PROBLEM=""
    if [[ ! -x "$VENV_PY" ]]; then PY_PROBLEM="the twin's Python environment does not exist yet"; bad "Python environment: $PY_PROBLEM"; return 1; fi
    local version; version="$("$VENV_PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)" || { PY_PROBLEM="its Python does not start"; bad "Python environment: $PY_PROBLEM"; return 1; }
    if ! "$VENV_PY" -c "import cryptography, ssl; assert ssl.HAS_TLSv1_3" >/dev/null 2>&1; then PY_PROBLEM="the cryptography package or TLS 1.3 is missing"; bad "Python $version: $PY_PROBLEM"; return 1; fi
    ok "Python $version with TLS 1.3 and cryptography ($VENV)"
    local home; home="$(sumo_home)"
    if [[ -n "$home" && -x "$home/bin/sumo$EXE" ]]; then
        SUMO_HOME="$home"; SUMO_BINARY="$home/bin/sumo$EXE"
    elif [[ -f "$RUNTIME/system-sumo" ]]; then
        SUMO_BINARY="$(cat "$RUNTIME/system-sumo" 2>/dev/null || command -v sumo)"; SUMO_HOME="$(dirname "$(dirname "$SUMO_BINARY")")/share/sumo"
    else
        PY_PROBLEM="SUMO $SUMO_VERSION is not installed in it"; bad "SUMO: not installed"; return 1
    fi
    local sumo_text; sumo_text="$(SUMO_HOME="$SUMO_HOME" "$SUMO_BINARY" --version 2>/dev/null | head -1)"
    if [[ "$sumo_text" != *"$SUMO_VERSION"* ]]; then
        if [[ -f "$RUNTIME/system-sumo" && -n "$sumo_text" ]]; then warn "SUMO: $sumo_text (system package; the twin is tested with $SUMO_VERSION)"
        else PY_PROBLEM="SUMO does not run ($sumo_text)"; bad "SUMO: does not run"; return 1; fi
    else
        ok "SUMO $SUMO_VERSION ($SUMO_BINARY)"
    fi
    if ! SUMO_HOME="$SUMO_HOME" "$VENV_PY" -c "import sys,os;sys.path.insert(0,os.path.join(os.environ['SUMO_HOME'],'tools'));import traci,sumolib" >/dev/null 2>&1; then
        PY_PROBLEM="TraCI does not import"; bad "TraCI: does not import"; return 1
    fi
    ok "TraCI and sumolib import"
    export SUMO_HOME SUMO_BINARY
    return 0
}
find_system_python() {
    local candidate
    for candidate in python3.13 python3.12 python3.14 python3.11 python3.10 python3 python; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        "$candidate" -c 'import sys; assert sys.version_info >= (3, 10)' >/dev/null 2>&1 || continue
        "$candidate" -c 'import venv, ensurepip, ssl' >/dev/null 2>&1 || continue
        command -v "$candidate"; return 0
    done
    return 1
}
ensure_uv() {
    UV=""
    if command -v uv >/dev/null 2>&1; then UV="$(command -v uv)"; return 0; fi
    local local_uv="$RUNTIME/uv/uv$EXE"
    if [[ -x "$local_uv" ]]; then UV="$local_uv"; return 0; fi
    ask "Download uv (a self-contained Python installer from github.com/astral-sh/uv, ~20 MB) into twin/.runtime/uv?" || return 1
    mkdir -p "$RUNTIME/uv" && local archive="$RUNTIME/uv/$UV_ASSET"
    download "https://github.com/astral-sh/uv/releases/latest/download/$UV_ASSET" "$archive" || { bad "uv download failed"; return 1; }
    download "https://github.com/astral-sh/uv/releases/latest/download/$UV_ASSET.sha256" "$archive.sha256" >/dev/null 2>&1 || true
    if [[ -s "$archive.sha256" ]] && [[ "$(sha_of 256 "$archive")" != "$(cut -d' ' -f1 "$archive.sha256")" ]]; then bad "uv checksum mismatch"; rm -f "$archive"; return 1; fi
    tar -xf "$archive" -C "$RUNTIME/uv" || { bad "could not unpack uv"; return 1; }
    find "$RUNTIME/uv" -name "uv$EXE" -type f -exec mv -f {} "$local_uv" \; 2>/dev/null
    chmod +x "$local_uv" 2>/dev/null
    [[ -x "$local_uv" ]] && UV="$local_uv"
}
install_python() {
    local system_python
    if [[ -d "$VENV" ]] && { [[ ! -x "$VENV_PY" ]] || ! "$VENV_PY" -c "import sys" >/dev/null 2>&1; }; then
        info "removing a broken Python environment (twin/.runtime/venv) to build it again"; rm -rf "$VENV"
    fi
    if [[ ! -x "$VENV_PY" ]]; then
        if system_python="$(find_system_python)"; then
            ask "Create the twin's private Python environment with $system_python ($("$system_python" -V 2>&1)) in twin/.runtime/venv?" || return 1
            "$system_python" -m venv "$VENV" >>"$SETUP_LOG" 2>&1 || { warn "venv creation failed with $system_python"; rm -rf "$VENV"; }
        fi
        if [[ ! -x "$VENV_PY" ]]; then
            info "no usable system Python 3.10+ with venv; using uv to install Python $UV_PYTHON privately"
            ensure_uv || return 1
            ask "Install Python $UV_PYTHON (python-build-standalone, ~30 MB) and create twin/.runtime/venv with uv?" || return 1
            "$UV" venv --python "$UV_PYTHON" --seed "$VENV" >>"$SETUP_LOG" 2>&1 || { bad "uv could not create the environment"; return 1; }
        fi
    fi
    ask "Install SUMO $SUMO_VERSION (eclipse-sumo, ~110 MB) and cryptography from PyPI into twin/.runtime/venv?" || return 1
    local pip_ok=0
    if "$VENV_PY" -m pip --version >/dev/null 2>&1; then
        "$VENV_PY" -m pip install --disable-pip-version-check --upgrade "${PYTHON_PACKAGES[@]}" 2>&1 | tee -a "$SETUP_LOG" | grep -E "^(Successfully|ERROR)" ; [[ ${PIPESTATUS[0]} -eq 0 ]] && pip_ok=1
    else
        ensure_uv && "$UV" pip install --python "$VENV_PY" "${PYTHON_PACKAGES[@]}" 2>&1 | tee -a "$SETUP_LOG" | tail -3; [[ ${PIPESTATUS[0]} -eq 0 ]] && pip_ok=1
    fi
    if ((pip_ok == 0)); then
        warn "pip could not install eclipse-sumo $SUMO_VERSION here (PyPI has wheels for Linux x86_64, macOS arm64 and Windows x86_64)"
        "$VENV_PY" -m pip install --disable-pip-version-check "cryptography>=42" >>"$SETUP_LOG" 2>&1 || { ensure_uv && "$UV" pip install --python "$VENV_PY" "cryptography>=42" >>"$SETUP_LOG" 2>&1; }
        install_system_sumo || return 1
    fi
}
install_system_sumo() {
    if command -v sumo >/dev/null 2>&1; then command -v sumo >"$RUNTIME/system-sumo"; info "using the system SUMO: $(sumo --version 2>/dev/null | head -1)"; return 0; fi
    case "$PKG" in
        apt-get) ask "Install SUMO from your distribution: 'sudo apt-get install -y sumo sumo-tools'?" && sudo apt-get install -y sumo sumo-tools ;;
        dnf) ask "Install SUMO: 'sudo dnf install -y sumo'?" && sudo dnf install -y sumo ;;
        pacman) ask "Install SUMO: 'sudo pacman -S --noconfirm sumo'?" && sudo pacman -S --noconfirm sumo ;;
        brew) ask "Install SUMO: 'brew install sumo'?" && brew install sumo ;;
        *) bad "install SUMO $SUMO_VERSION yourself (https://sumo.dlr.de/docs/Downloads.php) and run this script again"; return 1 ;;
    esac || return 1
    command -v sumo >"$RUNTIME/system-sumo" || return 1
}

# ------------------------------------------------------------------------------------------------- 3. Godot
check_godot() {
    if [[ ! -x "$GODOT_BIN" ]]; then bad "Godot $GODOT_VERSION: not installed"; return 1; fi
    local text; text="$("$GODOT_BIN" --headless --version 2>/dev/null | tail -1)"
    if [[ "$text" == "$GODOT_VERSION.stable.official"* ]]; then ok "Godot $text ($GODOT_BIN)"; return 0; fi
    bad "Godot: '$text' instead of $GODOT_VERSION.stable.official"; return 1
}
install_godot() {
    local legacy="$RUNTIME/legacy/linux-x86_64/godot"
    mkdir -p "$GODOT_DIR"
    if [[ "$OS-$ARCH" == "linux-x86_64" && -x "$legacy" ]] && [[ "$("$legacy" --headless --version 2>/dev/null | tail -1)" == "$GODOT_VERSION.stable.official"* ]]; then
        info "found the official Godot $GODOT_VERSION already on this machine (twin/.runtime/legacy); reusing it"
        cp -f "$legacy" "$GODOT_BIN" && chmod +x "$GODOT_BIN" && return 0
    fi
    ask "Download Godot $GODOT_VERSION ($GODOT_ZIP, ~60 MB) from github.com/godotengine/godot/releases?" || return 1
    local zip="$GODOT_DIR/$GODOT_ZIP" sums="$GODOT_DIR/SHA512-SUMS.txt"
    download "$GODOT_URL/$GODOT_ZIP" "$zip" || { bad "download failed"; return 1; }
    download "$GODOT_URL/SHA512-SUMS.txt" "$sums" >/dev/null 2>&1 || { bad "could not fetch the official checksums"; return 1; }
    local expected; expected="$(grep " $GODOT_ZIP\$" "$sums" | cut -d' ' -f1)"
    if [[ -z "$expected" || "$(sha_of 512 "$zip")" != "$expected" ]]; then bad "checksum does not match the official SHA-512: deleting the download"; rm -f "$zip"; return 1; fi
    ok "SHA-512 matches the official release"
    "$VENV_PY" -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$GODOT_DIR" 2>>"$SETUP_LOG" \
        || unzip -oq "$zip" -d "$GODOT_DIR" || { bad "could not unpack Godot"; return 1; }
    rm -f "$zip"
    chmod +x "$GODOT_BIN" 2>/dev/null
    [[ "$OS" == "macos" ]] && xattr -dr com.apple.quarantine "$GODOT_DIR/Godot.app" 2>/dev/null
    [[ -x "$GODOT_BIN" ]]
}

# ------------------------------------------------------------------------------------------------- 4. keys and config
key_identities() { "$VENV_PY" "$SRC/tools/launcher_tasks.py" identities; }
check_keys() {
    KEY_PROBLEMS=""
    local line dir name hosts out all_ok=0
    if ! out="$(key_identities 2>&1)"; then bad "twin.conf: $out"; return 2; fi
    while IFS='|' read -r dir name hosts; do
        [[ -z "$name" ]] && continue
        if result="$("$VENV_PY" "$SRC/tools/mcp/make_keys.py" --dir "$dir" --identity "$name=$hosts" --check 2>&1)"; then :; else KEY_PROBLEMS+="$result"$'\n'; all_ok=1; fi
    done <<<"$out"
    if ((all_ok == 0)); then ok "key pairs and certificates valid ($(echo "$out" | cut -d'|' -f2 | paste -sd, - | sed 's/,/, /g'))"; return 0; fi
    bad "key pairs: $(printf '%s\n' "$KEY_PROBLEMS" | grep -v '^$' | sort -u | paste -sd';' - | sed 's/;/; /g')"
    return 1
}
install_keys() {
    if [[ "$("$VENV_PY" "$SRC/tools/launcher_tasks.py" manage-keys)" != "yes" ]]; then
        bad "twin.conf says manage_keys = no: put valid PEM files where twin.conf points (see twin/INTERFACE.md)"; return 1
    fi
    local dir name hosts
    while IFS='|' read -r dir name hosts; do
        [[ -z "$name" ]] && continue
        "$VENV_PY" "$SRC/tools/mcp/make_keys.py" --dir "$dir" --identity "$name=$hosts" | sed 's/^/    /'
    done < <(key_identities)
}
check_config() {
    local out
    if ! out="$("$VENV_PY" "$SRC/tools/mcp/twin_gateway.py" --config "$CONF" --check 2>&1)"; then bad "twin.conf: $out"; return 1; fi
    ok "$out"
    if ! out="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" consistency 2>&1)"; then bad "twin.conf and twin/mocks/standins.conf disagree: $out"; return 1; fi
    ok "twin.conf and the stand-ins' standins.conf agree"
}

# ------------------------------------------------------------------------------------------------- 5. Godot import cache
check_import() {
    local marker="$SRC/.godot/.cgz_imported"
    if [[ ! -d "$SRC/.godot/imported" || ! -f "$marker" ]]; then bad "Godot import cache: not built yet (first run, or it was deleted)"; return 1; fi
    if [[ -n "$(find "$SRC" -path "$SRC/.godot" -prune -o \( -name '*.import' -o -name 'project.godot' \) -newer "$marker" -print -quit 2>/dev/null)" ]]; then
        bad "Godot import cache: assets changed since the last import"; return 1
    fi
    ok "Godot import cache ready"; return 0
}
install_import() {
    info "importing the city's assets with Godot (first time only; several minutes on a fresh checkout) ..."
    if "$GODOT_BIN" --headless --path "$SRC" --import >>"$SETUP_LOG" 2>&1 || [[ -d "$SRC/.godot/imported" ]]; then
        date '+%F %T' >"$SRC/.godot/.cgz_imported"; return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------------------------- 6. desktop entry (Linux)
register_launcher() {
    [[ "$OS" == "linux" && "${CITY_NO_LAUNCHER:-0}" != "1" ]] || return 0
    local applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications" icon="$SRC/assets/branding/lg-out.png"
    [[ -f "$icon" ]] || return 0
    mkdir -p "$applications" 2>/dev/null || return 0
    local content="[Desktop Entry]
Type=Application
Name=City Ground Zero
Comment=Live smart-city simulation and control room
Exec=\"$ROOT/run_control_room.sh\"
Icon=$icon
Terminal=true
Categories=Education;Science;
StartupWMClass=City Ground Zero
StartupNotify=true"
    local target="$applications/city-ground-zero.desktop"
    if [[ ! -f "$target" ]] || [[ "$(cat "$target")" != "$content" ]]; then
        printf '%s\n' "$content" >"$target" && chmod 644 "$target"
        command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$applications" >/dev/null 2>&1
    fi
    return 0
}

# ------------------------------------------------------------------------------------------------- setup / repair
heal() { # heal NAME CHECK INSTALL : check, repair up to twice, check again
    local name="$1" check_fn="$2" install_fn="$3" attempt
    "$check_fn" && return 0
    [[ "$mode" == "check" ]] && return 1
    for attempt in 1 2; do
        info "repairing: $name (attempt $attempt)"
        DECLINED=0
        if "$install_fn"; then "$check_fn" && { ok "$name repaired"; return 0; }; fi
        if ((DECLINED)); then warn "$name left as it is (you said no)"; return 1; fi
        [[ $attempt == 1 ]] && sleep 2
    done
    return 1
}
write_env() {
    cat >"$RUNTIME/env.sh" <<EOF
# Written by run_control_room.sh: the paths of this machine's twin runtime (for twin/tests/run_tests.sh).
export CGZ_ROOT="$ROOT" CGZ_SRC="$SRC" CGZ_GODOT="$GODOT_BIN" CGZ_PYTHON="$VENV_PY"
export SUMO_HOME="$SUMO_HOME" SUMO_BINARY="$SUMO_BINARY"
EOF
}
setup() {
    printf '%sCity Ground Zero%s · %s · %s/%s · project %s\n' "$B" "$N" "$(date '+%F %T')" "$OS" "$ARCH" "$ROOT"
    note "=== $mode on $OS/$ARCH"
    step "Checking what this machine has"
    local failed=()
    heal "downloader" check_tools install_tools || failed+=("downloader (curl or wget)")
    heal "Python environment and SUMO $SUMO_VERSION" check_python install_python || failed+=("Python + SUMO: ${PY_PROBLEM:-see above}")
    if [[ -x "$VENV_PY" ]]; then
        heal "Godot $GODOT_VERSION" check_godot install_godot || failed+=("Godot $GODOT_VERSION")
        heal "key pairs" check_keys install_keys || failed+=("key pairs (twin/keys)")
        check_config || failed+=("configuration (twin/twin.conf)")
        if [[ -x "$GODOT_BIN" ]]; then heal "Godot import cache" check_import install_import || failed+=("Godot import cache"); fi
    fi
    register_launcher
    if ((${#failed[@]})); then
        [[ "$mode" == "check" ]] && { warn "not ready: ${failed[*]}"; info "run ./run_control_room.sh --setup to install and repair"; exit 1; }
        die "Setup is incomplete: ${failed[*]}. Fix the item(s) above (the messages say how) and run the script again."
    fi
    write_env
    ok "everything is in place"
}

# ------------------------------------------------------------------------------------------------- running
pids=(); names=()
cleanup() {
    trap - EXIT INT TERM
    local index
    for ((index=${#pids[@]}-1; index>=0; index--)); do
        if kill -0 "${pids[$index]}" 2>/dev/null; then kill "${pids[$index]}" 2>/dev/null; fi
    done
    sleep 0.5
    local file pid
    for file in "$RUN_DIR"/*.pid; do
        [[ -f "$file" ]] || continue
        pid="$(cat "$file" 2>/dev/null)"
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
    done
    sleep 0.3
    for index in "${!pids[@]}"; do
        if kill -0 "${pids[$index]}" 2>/dev/null; then kill -9 "${pids[$index]}" 2>/dev/null; fi
        wait "${pids[$index]}" 2>/dev/null
    done
    rm -f "$RUN_DIR"/*.pid 2>/dev/null
}
start_bg() { # start_bg NAME LOGFILE command...
    local name="$1" log="$2"; shift 2
    "$@" >"$log" 2>&1 &
    local pid=$!
    pids+=("$pid"); names+=("$name")
    echo "$pid" >"$RUN_DIR/$name.pid"
    LAST_PID=$pid
}
stop_stale() {
    # Processes left by an earlier run of this script that was killed hard (their pid files are still here).
    local file pid
    for file in "$RUN_DIR"/*.pid; do
        [[ -f "$file" ]] || continue
        pid="$(cat "$file")"
        if kill -0 "$pid" 2>/dev/null; then warn "stopping $(basename "$file" .pid) left over from an earlier run (PID $pid)"; kill "$pid" 2>/dev/null; sleep 0.3; kill -9 "$pid" 2>/dev/null; fi
        rm -f "$file"
    done
}
check_ports() {
    local who host port
    while IFS='|' read -r who host port; do
        [[ -z "$port" ]] && continue
        if [[ "$("$VENV_PY" "$SRC/tools/launcher_tasks.py" port-owner "$port")" == "taken" ]]; then
            die "Port $port (the $who's MCP endpoint in twin.conf / standins.conf) is used by another program. Close it or choose another port in the .conf files."
        fi
    done < <("$VENV_PY" "$SRC/tools/launcher_tasks.py" endpoints)
    ok "MCP ports free: $("$VENV_PY" "$SRC/tools/launcher_tasks.py" endpoints | cut -d'|' -f3 | paste -sd' ' -)"
}
wait_for_file() { # wait_for_file FILE PID SECONDS
    local tries=$(( $3 * 10 ))
    while ((tries-- > 0)); do
        [[ -s "$1" ]] && return 0
        kill -0 "$2" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}
supervise() {
    # Keeps the partner links up: a gateway, stand-in or planner that stops is started again (at most 5 times each).
    # Runs in its own subshell: restarted processes are recorded in their pid files, which cleanup reads.
    local restarts=() index name
    while sleep 2; do
        for index in "${!pids[@]}"; do
            name="${names[$index]}"
            [[ "$name" == gateway || "$name" == brain || "$name" == guardian || "$name" == npc_planner ]] || continue
            kill -0 "${pids[$index]}" 2>/dev/null && continue
            restarts[$index]=$(( ${restarts[$index]:-0} + 1 ))
            (( ${restarts[$index]} > 5 )) && continue
            printf '%s[launcher] %s stopped; restarting it (%d/5), see %s%s\n' "$Y" "$name" "${restarts[$index]}" "$RUN_DIR/$name.log" "$N" >&2
            note "HEAL restart $name"
            case "$name" in
                gateway) "$VENV_PY" -u "$SRC/tools/mcp/twin_gateway.py" --config "$CONF" >>"$RUN_DIR/gateway.log" 2>&1 & ;;
                brain) "$VENV_PY" -u "$TWIN/mocks/brain_standin.py" >>"$RUN_DIR/brain.log" 2>&1 & ;;
                guardian) "$VENV_PY" -u "$TWIN/mocks/guardian_standin.py" >>"$RUN_DIR/guardian.log" 2>&1 & ;;
                npc_planner) "$VENV_PY" -u "$SRC/scripts/npc_ai_bridge.py" --port "$CITY_NPC_PLANNER_PORT" >>"$RUN_DIR/npc_planner.log" 2>&1 & ;;
            esac
            pids[$index]=$!
            echo "$!" >"$RUN_DIR/$name.pid"
        done
    done
}

run_city() {
    step "Starting City Ground Zero"
    [[ "$mode" == "editor" ]] || stop_stale
    [[ "$mode" == "editor" ]] || check_ports
    # The last launch's process logs are kept one generation back, so a failure can still be read after the next start.
    mkdir -p "$RUN_DIR/previous" && rm -f "$RUN_DIR/previous/"*.log && for log in "$RUN_DIR"/*.log; do [[ -f "$log" ]] && mv -f "$log" "$RUN_DIR/previous/"; done
    trap cleanup EXIT INT TERM HUP
    export PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
    unset PYTHONHOME
    local display_args=()
    if [[ "$OS" == "linux" && -n "${WAYLAND_DISPLAY:-}" && -n "${DISPLAY:-}" ]]; then display_args=(--display-driver "${CITY_DISPLAY_DRIVER:-x11}"); fi
    if [[ "$OS" == "linux" ]] && command -v nvidia-smi >/dev/null 2>&1 && timeout --kill-after=1s 2s nvidia-smi -L >/dev/null 2>&1; then
        export __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only
        info "renderer: NVIDIA (PRIME offload)"
    else
        info "renderer: the system's Vulkan GPU"
    fi
    export CITY_SUMO_UDP_PORT CITY_SUMO_CONTROL_PORT CITY_NPC_PLANNER_PORT CITY_SIM_API_PORT CITY_SIM_API_READY_FILE
    CITY_SUMO_UDP_PORT="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" free-port udp)"
    CITY_SUMO_CONTROL_PORT="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" free-port udp)"
    CITY_NPC_PLANNER_PORT="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" free-port tcp)"
    CITY_SIM_API_PORT="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" free-port tcp)"
    CITY_SIM_API_READY_FILE="$RUN_DIR/api_ready"
    rm -f "$CITY_SIM_API_READY_FILE" "$RUN_DIR/sumo_ready"

    local attempt
    for attempt in 1 2; do
        start_bg sumo_bridge "$RUN_DIR/sumo_bridge.log" "$VENV_PY" -u "$SRC/scripts/sumo_bridge.py" --rate 15 --port "$CITY_SUMO_UDP_PORT" --control-port "$CITY_SUMO_CONTROL_PORT" --ready-file "$RUN_DIR/sumo_ready"
        if wait_for_file "$RUN_DIR/sumo_ready" "$LAST_PID" 60; then ok "SUMO traffic bridge ready (PID $LAST_PID)"; break; fi
        bad "the SUMO bridge did not become ready (attempt $attempt):"; tail -n 8 "$RUN_DIR/sumo_bridge.log" | sed 's/^/      /'
        kill "$LAST_PID" 2>/dev/null
        [[ $attempt == 2 ]] && die "SUMO could not start; see $RUN_DIR/sumo_bridge.log"
        CITY_SUMO_UDP_PORT="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" free-port udp)"; CITY_SUMO_CONTROL_PORT="$("$VENV_PY" "$SRC/tools/launcher_tasks.py" free-port udp)"
    done
    start_bg npc_planner "$RUN_DIR/npc_planner.log" "$VENV_PY" -u "$SRC/scripts/npc_ai_bridge.py" --port "$CITY_NPC_PLANNER_PORT"
    ok "citizen planner running (PID $LAST_PID)"

    local scene_args=(--path "$SRC")
    [[ "$mode" == "editor" ]] && scene_args=(--editor --path "$SRC") || scene_args+=(--scene res://scenes/ControlRoom.tscn)
    start_bg godot "$RUN_DIR/godot.log" "$GODOT_BIN" "${display_args[@]+"${display_args[@]}"}" "${forwarded[@]+"${forwarded[@]}"}" "${scene_args[@]}"
    local godot_pid=$LAST_PID
    if [[ "$mode" == "editor" ]]; then
        ok "Godot editor open on twin/src (PID $godot_pid); close it to stop the traffic bridge"
        wait "$godot_pid"; return $?
    fi
    info "city window starting (PID $godot_pid, log twin/.runtime/run/godot.log)"
    if ! wait_for_file "$CITY_SIM_API_READY_FILE" "$godot_pid" 180; then
        bad "the city did not open its device interface"; tail -n 15 "$RUN_DIR/godot.log" | sed 's/^/      /'
        die "The city window failed to start; see $RUN_DIR/godot.log"
    fi
    CITY_SIM_API_PORT="$(cat "$CITY_SIM_API_READY_FILE")"
    ok "city running; device interface on 127.0.0.1:$CITY_SIM_API_PORT"

    local role script host port
    while IFS='|' read -r role script host port; do
        [[ -z "$role" ]] && continue
        start_bg "$role" "$RUN_DIR/$role.log" "$VENV_PY" -u "$script"
        ok "$role stand-in started (PID $LAST_PID, https://$host:$port, log twin/.runtime/run/$role.log)"
    done < <("$VENV_PY" "$SRC/tools/launcher_tasks.py" standins)
    start_bg gateway "$RUN_DIR/gateway.log" "$VENV_PY" -u "$SRC/tools/mcp/twin_gateway.py" --config "$CONF"
    ok "partner gateway started (PID $LAST_PID): run logs in logs/, timeline in the panel's Timeline tab"
    supervise &
    pids+=("$!"); names+=("supervisor")

    if ((dashboard)); then
        local open_flag=(); ((dashboard_open)) && open_flag=(--open)
        start_bg dashboard "$RUN_DIR/dashboard.log" "$VENV_PY" -u "$SRC/tools/dashboard/dashboard_server.py" --port "$dashboard_port" "${open_flag[@]+"${open_flag[@]}"}"
        export CITY_DASHBOARD_URL="http://127.0.0.1:${dashboard_port}/"
        ok "web dashboard: $CITY_DASHBOARD_URL"
    fi
    export CITY_GODOT_PID="$godot_pid"
    local status
    if [[ "$mode" == "scenario" ]]; then
        step "Scenario $scenario"
        # In the background and waited for, so that a stop signal reaches the cleanup at once.
        "$VENV_PY" -u "$SRC/tools/scenario/run_scenario.py" --scenario "$scenario" --config "$CONF" &
        local runner=$!
        pids+=("$runner"); names+=("scenario")
        wait "$runner"
        status=$?
        if ((status == 0)); then ok "scenario $scenario finished; closing the city"; else bad "scenario $scenario did not complete (exit $status); closing the city"; fi
        return $status
    fi
    if [[ "${CITY_NO_CLI:-0}" == "1" ]]; then
        info "running without the terminal (CITY_NO_CLI=1); close the city window to stop"
        wait "$godot_pid"; return $?
    fi
    step "MCP terminal (type help; closing the city window ends it too)"
    "$VENV_PY" "$SRC/tools/mcp/city_cli.py"
    status=$?
    if kill -0 "$godot_pid" 2>/dev/null; then echo "MCP terminal closed — closing the city…"; else echo "City window closed — closing the MCP terminal…"; fi
    return $status
}

# ------------------------------------------------------------------------------------------------- main
# The editor can be open next to a running control room: it keeps its own run files.
[[ "$mode" == "editor" ]] && RUN_DIR="$RUNTIME/run-editor" && mkdir -p "$RUN_DIR"
detect_platform
case "$mode" in
    check) setup; exit 0 ;;
    setup) setup; printf '\n%sReady.%s Start the control room with ./run_control_room.sh\n' "$G" "$N"; exit 0 ;;
    tests) setup; exec bash "$TWIN/tests/run_tests.sh" "${forwarded[@]+"${forwarded[@]}"}" ;;
    scenario) [[ -n "$scenario" ]] || die "--scenario needs an id (T01 ... T10; see scenarios/)"; setup; run_city; exit $? ;;
    *) setup; run_city; exit $? ;;
esac
