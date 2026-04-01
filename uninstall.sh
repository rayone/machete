#!/bin/bash
# ==============================================================================
# UNINSTALLER — macOS / Apple Silicon
# Comprehensively discovers and removes every piece of user-installed software.
# Requires only vanilla macOS tools — no python3, node, or any runtime.
# Never touches /System/** (SSV — sealed system volume).
#
# USAGE:
#   sudo ./uninstall.sh [OPTIONS]
#
# OPTIONS:
#   --dry-run        Show what would be removed; make no changes
#   --yes            Skip all confirmation prompts
#   --list           List all discovered items and exit
#   --category c,…   Run only these categories (comma-separated, see below)
#   --skip a,b       Skip items by name (comma-separated substring match)
#
# CATEGORIES:
#   apps             .app bundles in /Applications and ~/Applications
#   pkgs             pkgutil-registered packages (CLT, third-party installers)
#   brew             Homebrew formulas and casks
#   pip              pip user packages and pipx apps
#   node             npm global packages and nvm node versions
#   langs            Language version managers (pyenv, rbenv, cargo, volta…)
#   system           Kexts, system extensions, LaunchAgents/Daemons, helpers
#
# CONFIRMATION (default — interactive without --yes or --dry-run):
#   Prompt: [y] remove  [n] skip  [a] remove all remaining  [q] quit
# ==============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths & arguments
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/uninstall-$(date +%Y%m%d-%H%M%S).log"

DRY_RUN=false
YES_ALL=false
LIST_ONLY=false
CATEGORY_FILTER=""   # empty = show menu; "all" or "apps,pkgs,…" = skip menu
SKIP_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true ;;
        --yes)       YES_ALL=true ;;
        --list)      LIST_ONLY=true ;;
        --category)  CATEGORY_FILTER="$2"; shift ;;
        --skip)      SKIP_FILTER="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ts()     { date '+%H:%M:%S'; }
log()    { echo "  [$(ts)] $*"; }
ok()     { echo "  [$(ts)] OK  $*"; }
warn()   { echo "  [$(ts)] WARN $*"; }
err()    { echo "  [$(ts)] ERR  $*"; }
header() { echo ""; echo "======================================================================"; echo "  $*"; echo "======================================================================"; }
sep()    { echo "  ──────────────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
# Real user detection — sudo-safe
# ---------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER=$(logname 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER="$USER"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "$(id -u)")

# ---------------------------------------------------------------------------
# SSV guard
# ---------------------------------------------------------------------------
_ssv_guard() {
    case "$1" in /System/*|/System)
        err "SAFETY: refusing SSV path: $1"; return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Skip filter
# ---------------------------------------------------------------------------
_should_skip() {
    [ -z "$SKIP_FILTER" ] && return 1
    local skip_re
    skip_re=$(echo "$SKIP_FILTER" | tr ',' '|')
    echo "$1" | grep -qiE "($skip_re)"
}

# ---------------------------------------------------------------------------
# Category filter — returns 0 if this type should be processed
# Types map to categories:
#   apps        → app
#   pkgs        → pkg
#   brew        → brew_formula brew_cask
#   pip         → pip pipx
#   node        → npm nvm
#   langs       → cargo rustup gobin langdir
#   system      → kext sysext agent daemon helper
# ---------------------------------------------------------------------------
ACTIVE_CATEGORIES=""   # set after menu or --category arg

_category_active() {
    local type="$1"
    case "$ACTIVE_CATEGORIES" in *all*) return 0 ;; esac
    case "$type" in
        app)                        case "$ACTIVE_CATEGORIES" in *apps*)   return 0 ;; esac ;;
        pkg)                        case "$ACTIVE_CATEGORIES" in *pkgs*)   return 0 ;; esac ;;
        brew_formula|brew_cask)     case "$ACTIVE_CATEGORIES" in *brew*)   return 0 ;; esac ;;
        pip|pipx)                   case "$ACTIVE_CATEGORIES" in *pip*)    return 0 ;; esac ;;
        npm|nvm)                    case "$ACTIVE_CATEGORIES" in *node*)   return 0 ;; esac ;;
        cargo|rustup|gobin|langdir) case "$ACTIVE_CATEGORIES" in *langs*)  return 0 ;; esac ;;
        kext|sysext|agent|daemon|helper) case "$ACTIVE_CATEGORIES" in *system*) return 0 ;; esac ;;
    esac
    return 1
}

# ---------------------------------------------------------------------------
# Realpath — follow symlinks without python3
# ---------------------------------------------------------------------------
_realpath() {
    local path="$1" target dir
    local i=0
    while [ $i -lt 10 ]; do
        target=$(stat -f "%Y" "$path" 2>/dev/null || true)
        [ -z "$target" ] && break
        case "$target" in
            /*)  path="$target" ;;
            *)   dir=$(dirname "$path")
                 path="$dir/$target"
                 path=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path") || path="$path"
                 ;;
        esac
        i=$((i+1))
    done
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Artifact matcher — pure bash, no external runtime
# ---------------------------------------------------------------------------
_TOKENS=""
_TOKEN_SKIP="com org io net co app inc llc the get pkg bin lib usr var etc opt"

_build_tokens() {
    local id="$1" display="$2"
    _TOKENS=""

    _add_token() {
        local t
        t=$(echo "$1" | tr '[:upper:]' '[:lower:]')
        [ "${#t}" -lt 4 ] && return
        case " $_TOKEN_SKIP " in *" $t "*) return ;; esac
        case "$_TOKENS" in *"
$t"*) return ;; esac
        _TOKENS="${_TOKENS}
$t"
    }

    _add_token "$id"
    local IFS_SAVE="$IFS"
    IFS='.'; set -- $id; IFS="$IFS_SAVE"
    for part; do
        local p2
        for p2 in $(echo "$part" | tr '-' ' ' | tr '_' ' '); do
            _add_token "$p2"
        done
    done
    local word
    for word in $(echo "$display" | tr '-' ' ' | tr '_' ' '); do
        _add_token "$word"
    done
}

_artifact_matches() {
    local candidate="$1"
    case "$candidate" in *.plist) candidate="${candidate%.plist}" ;; esac
    local cl
    cl=$(echo "$candidate" | tr '[:upper:]' '[:lower:]')

    while IFS= read -r tok; do
        [ -z "$tok" ] && continue
        [ "$cl" = "$tok" ] && return 0
        case "$cl" in *"$tok"*)
            [ "${#tok}" -ge 8 ] && return 0 ;;
        esac
    done <<< "$_TOKENS"

    local comp
    for comp in $(echo "$cl" | tr '._- ' ' '); do
        [ "${#comp}" -lt 4 ] && continue
        while IFS= read -r tok; do
            [ -z "$tok" ] && continue
            [ "$comp" = "$tok" ] && return 0
        done <<< "$_TOKENS"
    done
    return 1
}

# ---------------------------------------------------------------------------
# Library artifact scanner
# ---------------------------------------------------------------------------
find_artifacts() {
    local id="$1" display="$2"
    _build_tokens "$id" "$display"
    local found_str="" base_dir pattern entry name

    _scan() {
        base_dir="$1"; pattern="$2"
        [ -d "$base_dir" ] || return 0
        while IFS= read -r -d '' entry; do
            name=$(basename "$entry")
            _artifact_matches "$name" || continue
            case "$found_str" in *"
$entry"*) continue ;; esac
            found_str="${found_str}
$entry"
        done < <(find "$base_dir" -maxdepth 1 -mindepth 1 -name "$pattern" -print0 2>/dev/null)
    }

    _scan "$REAL_HOME/Library/Application Support"     "*"
    _scan "$REAL_HOME/Library/Group Containers"        "*"
    _scan "$REAL_HOME/Library/Containers"              "*"
    _scan "$REAL_HOME/Library/Preferences"             "*.plist"
    _scan "$REAL_HOME/Library/Caches"                  "*"
    _scan "$REAL_HOME/Library/Logs"                    "*"
    _scan "$REAL_HOME/Library/Saved Application State" "*"
    _scan "$REAL_HOME/Library/WebKit"                  "*"
    _scan "/Library/Application Support"               "*"
    _scan "/Library/Preferences"                       "*.plist"
    _scan "/Library/PrivilegedHelperTools"              "*"

    while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$p"; done <<< "$found_str"
}

# ---------------------------------------------------------------------------
# LaunchAgent/Daemon scanner
# ---------------------------------------------------------------------------
find_agents() {
    local id="$1"
    local prefix agent_dir domain plist label
    prefix=$(printf '%s' "$id" | awk -F'.' '{print $1"."$2}')

    _agent_scan() {
        agent_dir="$1"; domain="$2"
        [ -d "$agent_dir" ] || return 0
        while IFS= read -r -d '' plist; do
            label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null || true)
            [ -z "$label" ] && continue
            case "$label" in "${id}"*|"${prefix}"*)
                printf '%s|%s\n' "$domain/$label" "$plist" ;;
            esac
        done < <(find "$agent_dir" -maxdepth 1 -name "*.plist" -print0 2>/dev/null)
    }

    _agent_scan "$REAL_HOME/Library/LaunchAgents" "gui/$REAL_UID"
    _agent_scan "/Library/LaunchAgents"            "gui/$REAL_UID"
    _agent_scan "/Library/LaunchDaemons"           "system"
}

# ---------------------------------------------------------------------------
# Removal primitives
# ---------------------------------------------------------------------------
_rm() {
    local path="$1"
    _ssv_guard "$path" || return 1
    [ -e "$path" ] || [ -L "$path" ] || return 0
    local size; size=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")
    if [ "$DRY_RUN" = true ]; then
        printf "    [DRY]  rm -rf  %-55s  (%s)\n" "$path" "$size"
        return 0
    fi
    rm -rf "$path" 2>/dev/null \
        && ok "  rm -rf $path  ($size)" \
        || warn "  Could not remove: $path"
}

_rm_agent() {
    local domain_label="$1" plist_path="$2"
    _ssv_guard "$plist_path" || return 1
    if [ "$DRY_RUN" = true ]; then
        printf "    [DRY]  launchctl disable  %s\n" "$domain_label"
        printf "    [DRY]  rm                 %s\n" "$plist_path"
        return 0
    fi
    launchctl disable "$domain_label" 2>/dev/null || true
    launchctl bootout "$domain_label"  2>/dev/null || true
    _rm "$plist_path"
}

_kill_bundle() {
    local bundle_path="$1"
    local pid
    pid=$(lsappinfo info -only pid "$bundle_path" 2>/dev/null \
        | awk -F'= ' '{print $2}' | tr -d ' "' || true)
    [ -z "$pid" ] || [ "$pid" = "0" ] && return 0
    if [ "$DRY_RUN" = true ]; then
        printf "    [DRY]  kill PID %s  (%s)\n" "$pid" "$(basename "$bundle_path" .app)"
        return 0
    fi
    kill "$pid" 2>/dev/null || true; sleep 0.3; kill -9 "$pid" 2>/dev/null || true
    ok "  Terminated PID $pid"
}

_forget_receipt() {
    local pkg_id="$1"
    pkgutil --forget "$pkg_id" 2>/dev/null || true
    if pkgutil --pkg-info "$pkg_id" &>/dev/null; then
        local apple_receipts="/Library/Apple/System/Library/Receipts"
        for f in "$apple_receipts/${pkg_id}.plist" "$apple_receipts/${pkg_id}.bom"; do
            [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
        done
        if pkgutil --pkg-info "$pkg_id" &>/dev/null; then
            warn "  Receipt $pkg_id still present — SIP may need to be disabled"
        else
            ok "  Receipt removed from Apple receipt store"
        fi
    else
        ok "  pkgutil --forget $pkg_id"
    fi
}

_rm_pkg() {
    local pkg_id="$1"
    local SHARED="/Library|/Library/Developer|/usr|/usr/bin|/usr/sbin|/usr/lib|/usr/libexec|/usr/share|/usr/local|/private|/private/var|/etc|/var|/bin|/sbin|/Library/LaunchAgents|/Library/LaunchDaemons|/Library/Preferences|/Library/Application Support"

    log "  Resolving install root for $pkg_id ..."

    local install_root
    install_root=$(pkgutil --files "$pkg_id" 2>/dev/null \
        | awk -v shared="$SHARED" '
        BEGIN { n = split(shared, s, "|") }
        {
            p = "/" $0
            depth = gsub("/", "/", p)
            if (depth < 3) next
            skip = 0
            for (i = 1; i <= n; i++) { if (p == s[i]) { skip = 1; break } }
            if (skip) next
            print p
            exit
        }')

    if [ -z "$install_root" ]; then
        warn "  Cannot determine safe install root for $pkg_id — attempting receipt removal only"
        [ "$DRY_RUN" = false ] && _forget_receipt "$pkg_id"
        return 0
    fi

    _ssv_guard "$install_root" || return 1

    if [ "$DRY_RUN" = true ]; then
        local sz; sz=$(du -sh "$install_root" 2>/dev/null | cut -f1 || echo "?")
        printf "    [DRY]  pkgutil --forget  %s\n" "$pkg_id"
        printf "    [DRY]  rm -rf  %-55s  (%s)\n" "$install_root" "$sz"
        return 0
    fi
    _rm "$install_root"
    _forget_receipt "$pkg_id"
}

# ---------------------------------------------------------------------------
# Confirmation engine — y/n/a/q
# ---------------------------------------------------------------------------
_accept_all=false

confirm_item() {
    if [ "$DRY_RUN" = true ] || [ "$YES_ALL" = true ] || [ "$_accept_all" = true ]; then
        return 0
    fi
    printf "  Remove? [y/n/a/q]: "
    local ans ans_lower
    read -r ans < /dev/tty
    ans_lower=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans_lower" in
        y|yes)  return 0 ;;
        n|no)   return 1 ;;
        a|all)  _accept_all=true; return 0 ;;
        q|quit) log "Quit by user."; echo ""; exit 0 ;;
        *)      warn "Unrecognised — skipping"; return 1 ;;
    esac
}

# ===========================================================================
# DISCOVERY
# ===========================================================================

discover_apps() {
    local dir bundle real info_plist bundle_id display_name
    for dir in "/Applications" "$REAL_HOME/Applications"; do
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' bundle; do
            real=$(_realpath "$bundle")
            case "$real" in /System/*) continue ;; esac
            info_plist="$bundle/Contents/Info.plist"
            [ -f "$info_plist" ] || continue
            bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                        "$info_plist" 2>/dev/null || true)
            display_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" \
                           "$info_plist" 2>/dev/null \
                        || /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" \
                           "$info_plist" 2>/dev/null \
                        || basename "$bundle" .app)
            [ -z "$bundle_id" ] && bundle_id="unknown"
            _should_skip "$(basename "$bundle" .app)" && continue
            _should_skip "$display_name"              && continue
            printf '%s|%s|%s|app|%s\n' \
                "$(basename "$bundle" .app)" "$display_name" "$bundle_id" "$bundle"
        done < <(find "$dir" -maxdepth 1 -name "*.app" -print0 2>/dev/null)
    done
}

_OS_PKG_RE='com\.apple\.(pkg\.(macOS|Mac_OS|OSX|Rosetta|XProtect|MRT|TCC|KEXT|Security|Boot|Recovery|Update|Seed|Safari|iCloud|Photos|Mail|Calendar|Contacts|Notes|Messages|FaceTime|Music|TV|Podcasts|News|Stocks|Weather|Maps|Wallet|Home|GameCenter|ScreenTime|TimeMachine|Accessibility|BaseSystem|Core|BSD|Print|iWork|Pages|Numbers|Keynote|GarageBand|iMovie|Motion|Compressor|LogicPro|FinalCut|AppleTV|AppleMusic|Configurator|InstrumentsAdditional|AppleRemoteDesktop|ServerBackup|FocusFlow|MediaLibrary|iTunesRemote|iOSSupport|MobileDeviceSupport|DeviceSupport|XcodeSystemResources|XcodeDocset|CoreGPU)|files\.|configurationprofiles|mdm)'

discover_pkgs() {
    local pkg_id display_name loc raw
    while IFS= read -r pkg_id; do
        [ -z "$pkg_id" ] && continue
        echo "$pkg_id" | grep -qE "$_OS_PKG_RE" && continue
        loc=$(pkgutil --pkg-info "$pkg_id" 2>/dev/null | awk '/^location:/{print $2}')
        case "$loc" in /System/*) continue ;; esac
        raw="$pkg_id"
        raw="${raw#*.}"; raw="${raw#*.}"
        case "$raw" in pkg.*) raw="${raw#pkg.}" ;; esac
        display_name="${raw//_/ }"; display_name="${display_name//./ }"
        [ -z "$display_name" ] && display_name="$pkg_id"
        _should_skip "$pkg_id"       && continue
        _should_skip "$display_name" && continue
        printf '%s|%s|%s|pkg|%s\n' "$pkg_id" "$display_name" "$pkg_id" "$pkg_id"
    done < <(pkgutil --pkgs 2>/dev/null)
}

_BREW=""
for _b in \
    "$(command -v brew 2>/dev/null)" \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew \
    /home/linuxbrew/.linuxbrew/bin/brew; do
    [ -x "$_b" ] && _BREW="$_b" && break
done
_BREW_PREFIX=""
[ -n "$_BREW" ] && _BREW_PREFIX="$(dirname "$(dirname "$_BREW")")"

discover_brew_formulas() {
    [ -z "$_BREW" ] && return 0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        _should_skip "$f" && continue
        printf 'brew:%s|%s (brew formula)|%s|brew_formula|%s\n' \
            "$f" "$f" "$f" "$_BREW_PREFIX/opt/$f"
    done < <("$_BREW" list --formula 2>/dev/null)
}

discover_brew_casks() {
    [ -z "$_BREW" ] && return 0
    local c
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        _should_skip "$c" && continue
        printf 'cask:%s|%s (brew cask)|%s|brew_cask|%s\n' \
            "$c" "$c" "$c" "$_BREW_PREFIX/Caskroom/$c"
    done < <("$_BREW" list --cask 2>/dev/null)
}

_PIP=""
for _p in \
    /opt/homebrew/bin/pip3 /opt/homebrew/bin/pip \
    /usr/local/bin/pip3 \
    "$REAL_HOME/Library/Python/3.9/bin/pip3" \
    "$REAL_HOME/Library/Python/3.11/bin/pip3" \
    "$REAL_HOME/.local/bin/pip3"; do
    [ -x "$_p" ] && _PIP="$_p" && break
done

discover_pip() {
    [ -z "$_PIP" ] && return 0
    local pkg ver site_dir
    while IFS= read -r line; do
        pkg=$(echo "$line" | awk '{print $1}')
        ver=$(echo "$line" | awk '{print $2}')
        [ -z "$pkg" ] && continue
        case "$pkg" in Package|"---"*) continue ;; esac
        _should_skip "$pkg" && continue
        site_dir=$("$_PIP" show "$pkg" 2>/dev/null | awk '/^Location:/{print $2}')
        printf 'pip:%s|%s %s (pip)|%s|pip|%s\n' \
            "$pkg" "$pkg" "$ver" "$pkg" "${site_dir:-unknown}"
    done < <("$_PIP" list --user 2>/dev/null)
}

_PIPX=$(command -v pipx 2>/dev/null || true)

discover_pipx() {
    [ -z "$_PIPX" ] && return 0
    local app
    while IFS= read -r app; do
        [ -z "$app" ] && continue
        _should_skip "$app" && continue
        printf 'pipx:%s|%s (pipx)|%s|pipx|%s\n' \
            "$app" "$app" "$app" \
            "${PIPX_HOME:-$REAL_HOME/.local/share/pipx}/venvs/$app"
    done < <("$_PIPX" list --short 2>/dev/null | awk '{print $1}')
}

_NPM=""
for _n in \
    "$(command -v npm 2>/dev/null)" \
    /opt/homebrew/bin/npm \
    /usr/local/bin/npm; do
    [ -x "$_n" ] && _NPM="$_n" && break
done

discover_npm() {
    [ -z "$_NPM" ] && return 0
    local pkg ver npm_root
    npm_root=$("$_NPM" root -g 2>/dev/null || true)
    "$_NPM" list -g --depth=0 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        pkg=$(echo "$line" | sed 's/^[^a-zA-Z@]*//' | awk -F'@' '{print $1}' | tr -d ' ')
        ver=$(echo "$line" | awk -F'@' '{print $NF}' | tr -d ' ')
        [ -z "$pkg" ] || [ "$pkg" = "npm" ] && continue
        _should_skip "$pkg" && continue
        printf 'npm:%s|%s %s (npm global)|%s|npm|%s\n' \
            "$pkg" "$pkg" "$ver" "$pkg" "${npm_root:+$npm_root/$pkg}"
    done
}

discover_nvm() {
    local nvm_dir="${NVM_DIR:-$REAL_HOME/.nvm}"
    [ -d "$nvm_dir/versions" ] || return 0
    local vdir vname
    for vdir in "$nvm_dir/versions/node"/*/; do
        [ -d "$vdir" ] || continue
        vname=$(basename "$vdir")
        _should_skip "nvm-$vname" && continue
        printf 'nvm:%s|Node.js %s (nvm)|nvm-%s|nvm|%s\n' "$vname" "$vname" "$vname" "$vdir"
    done
}

discover_cargo() {
    local d="${CARGO_HOME:-$REAL_HOME/.cargo}"
    [ -d "$d" ] || return 0
    _should_skip "cargo" && return 0
    printf 'cargo|Rust/Cargo toolchain (~/.cargo)|cargo|cargo|%s\n' "$d"
}

discover_rustup() {
    local d="${RUSTUP_HOME:-$REAL_HOME/.rustup}"
    [ -d "$d" ] || return 0
    _should_skip "rustup" && return 0
    printf 'rustup|Rustup toolchain manager (~/.rustup)|rustup|rustup|%s\n' "$d"
}

discover_go() {
    local gopath="${GOPATH:-$REAL_HOME/go}"
    [ -d "$gopath/bin" ] || return 0
    local bin bname
    for bin in "$gopath/bin"/*; do
        [ -f "$bin" ] || continue
        bname=$(basename "$bin")
        _should_skip "$bname" && continue
        printf 'gobin:%s|%s (go binary)|%s|gobin|%s\n' "$bname" "$bname" "$bname" "$bin"
    done
}

discover_langdirs() {
    local dir pyver

    _ld() {
        [ -d "$3" ] || return 0
        _should_skip "$1" && return 0
        printf '%s|%s|%s|langdir|%s\n' "$1" "$2" "$1" "$3"
    }

    _ld pyenv  "pyenv (Python version manager)"        "$REAL_HOME/.pyenv"
    _ld rbenv  "rbenv (Ruby version manager)"          "$REAL_HOME/.rbenv"
    _ld rvm    "RVM (Ruby version manager)"            "$REAL_HOME/.rvm"
    _ld sdkman "SDKMAN (JVM version manager)"          "$REAL_HOME/.sdkman"
    _ld asdf   "asdf (multi-language version manager)" "$REAL_HOME/.asdf"
    _ld volta  "Volta (Node version manager)"          "$REAL_HOME/.volta"
    _ld fnm    "fnm (Node version manager)"            "$REAL_HOME/.fnm"

    for dir in "$REAL_HOME/Library/Python"/*/; do
        [ -d "$dir/lib/python/site-packages" ] || continue
        pyver=$(basename "$dir")
        _should_skip "pip-user-$pyver" && continue
        printf 'pip-user:%s|Python %s user site-packages|pip-user-%s|langdir|%s\n' \
            "$pyver" "$pyver" "$pyver" "$dir"
    done

    for dir in "$REAL_HOME/.local/lib/python"*/; do
        [ -d "$dir" ] || continue
        pyver=$(basename "$dir")
        _should_skip "pip-local-$pyver" && continue
        printf 'pip-local:%s|Python %s local packages|pip-local-%s|langdir|%s\n' \
            "$pyver" "$pyver" "$pyver" "$dir"
    done
}

discover_kexts() {
    local kext bundle_id display_name
    for kext in /Library/Extensions/*.kext; do
        [ -d "$kext" ] || continue
        bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
                    "$kext/Contents/Info.plist" 2>/dev/null || basename "$kext" .kext)
        case "$bundle_id" in com.apple.*) continue ;; esac
        display_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" \
                       "$kext/Contents/Info.plist" 2>/dev/null || basename "$kext" .kext)
        _should_skip "$display_name" && continue
        _should_skip "$bundle_id"    && continue
        printf 'kext:%s|%s (kext)|%s|kext|%s\n' "$bundle_id" "$display_name" "$bundle_id" "$kext"
    done
}

discover_sysext() {
    local line ext_id ext_name
    while IFS= read -r line; do
        ext_id=$(echo "$line" | grep -oE '[a-z][a-z0-9.]+\([0-9]' | sed 's/(.*//' || true)
        ext_name=$(echo "$line" | awk '{print $NF}')
        [ -z "$ext_id" ] && continue
        case "$ext_id" in com.apple.*) continue ;; esac
        _should_skip "$ext_id"   && continue
        _should_skip "$ext_name" && continue
        printf 'sysext:%s|%s (system extension)|%s|sysext|%s\n' \
            "$ext_id" "$ext_name" "$ext_id" "$ext_id"
    done < <(systemextensionsctl list 2>/dev/null)
}

discover_agents() {
    local plist label
    for plist in "$REAL_HOME/Library/LaunchAgents"/*.plist /Library/LaunchAgents/*.plist; do
        [ -f "$plist" ] || continue
        label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null || true)
        [ -z "$label" ] && continue
        case "$label" in com.apple.*) continue ;; esac
        _should_skip "$label" && continue
        printf 'agent:%s|%s (LaunchAgent)|%s|agent|%s\n' "$label" "$label" "$label" "$plist"
    done
}

discover_daemons() {
    local plist label
    for plist in /Library/LaunchDaemons/*.plist; do
        [ -f "$plist" ] || continue
        label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null || true)
        [ -z "$label" ] && continue
        case "$label" in com.apple.*) continue ;; esac
        _should_skip "$label" && continue
        printf 'daemon:%s|%s (LaunchDaemon)|%s|daemon|%s\n' "$label" "$label" "$label" "$plist"
    done
}

discover_helpers() {
    local helper bid
    for helper in /Library/PrivilegedHelperTools/*; do
        [ -e "$helper" ] || continue
        bid=$(basename "$helper")
        case "$bid" in com.apple.*) continue ;; esac
        _should_skip "$bid" && continue
        printf 'helper:%s|%s (PrivilegedHelper)|%s|helper|%s\n' "$bid" "$bid" "$bid" "$helper"
    done
}

# ===========================================================================
# MAIN
# ===========================================================================

header "UNINSTALLER — macOS $(sw_vers -productVersion)"
log "Log:      $LOG"
log "Dry run:  $DRY_RUN"
log "Yes all:  $YES_ALL"
log "User:     $REAL_USER (home: $REAL_HOME)"
log "Scanning all vectors ..."

# Collect everything first (fast — no --prefix per formula, no python3)
ALL_ENTRIES=()
while IFS= read -r line; do
    [ -n "$line" ] && ALL_ENTRIES+=("$line")
done < <(
    discover_apps
    discover_pkgs
    discover_brew_formulas
    discover_brew_casks
    discover_pip
    discover_pipx
    discover_npm
    discover_nvm
    discover_cargo
    discover_rustup
    discover_go
    discover_langdirs
    discover_kexts
    discover_sysext
    discover_agents
    discover_daemons
    discover_helpers
)

TOTAL=${#ALL_ENTRIES[@]}

if [ "$TOTAL" -eq 0 ]; then
    warn "No user-installed software found."
    exit 0
fi

log "Found $TOTAL item(s)"

# ---------------------------------------------------------------------------
# Build per-category counts for the menu
# ---------------------------------------------------------------------------
_count_type() {
    local type="$1" count=0 entry t
    for entry in "${ALL_ENTRIES[@]}"; do
        t=$(echo "$entry" | cut -d'|' -f4)
        case "$1" in
            apps)   case "$t" in app)                        count=$((count+1)) ;; esac ;;
            pkgs)   case "$t" in pkg)                        count=$((count+1)) ;; esac ;;
            brew)   case "$t" in brew_formula|brew_cask)     count=$((count+1)) ;; esac ;;
            pip)    case "$t" in pip|pipx)                   count=$((count+1)) ;; esac ;;
            node)   case "$t" in npm|nvm)                    count=$((count+1)) ;; esac ;;
            langs)  case "$t" in cargo|rustup|gobin|langdir) count=$((count+1)) ;; esac ;;
            system) case "$t" in kext|sysext|agent|daemon|helper) count=$((count+1)) ;; esac ;;
        esac
    done
    echo "$count"
}

CNT_APPS=$(  _count_type apps)
CNT_PKGS=$(  _count_type pkgs)
CNT_BREW=$(  _count_type brew)
CNT_PIP=$(   _count_type pip)
CNT_NODE=$(  _count_type node)
CNT_LANGS=$( _count_type langs)
CNT_SYSTEM=$(_count_type system)

# ---------------------------------------------------------------------------
# --list  (shows all items grouped by category, no menu needed)
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = true ]; then
    header "DISCOVERED ITEMS — $TOTAL"
    IDX=0
    current_type=""
    for entry in "${ALL_ENTRIES[@]}"; do
        IDX=$((IDX + 1))
        DISPLAY=$(echo "$entry" | cut -d'|' -f2)
        TYPE=$(echo "$entry"    | cut -d'|' -f4)
        DETAIL=$(echo "$entry"  | cut -d'|' -f5)
        if [ "$TYPE" != "$current_type" ]; then
            echo ""
            printf "  ── %s ──\n" "$TYPE"
            current_type="$TYPE"
        fi
        printf "  %3d  %-50s %s\n" "$IDX" "$DISPLAY" "$DETAIL"
    done
    echo ""
    echo "  Total: $TOTAL  |  Use --skip <name> to exclude items"
    exit 0
fi

# ---------------------------------------------------------------------------
# Category menu — shown unless --category was passed or --yes/--dry-run
# ---------------------------------------------------------------------------
if [ -z "$CATEGORY_FILTER" ] && [ "$YES_ALL" = false ] && [ "$DRY_RUN" = false ]; then
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │                  SELECT CATEGORY TO UNINSTALL                   │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "0"  "All"                     "$TOTAL"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "1"  "Apps (.app)"             "$CNT_APPS"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "2"  "Packages (pkgutil)"      "$CNT_PKGS"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "3"  "Homebrew"                "$CNT_BREW"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "4"  "pip / pipx"              "$CNT_PIP"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "5"  "Node / npm / nvm"        "$CNT_NODE"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "6"  "Lang managers"           "$CNT_LANGS"
    printf "  │  %-4s  %-20s  %3s items                               │\n" "7"  "System (kext/agents…)"   "$CNT_SYSTEM"
    echo "  │                                                                 │"
    echo "  │  Enter numbers separated by spaces, or press Enter for All:     │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    printf "  Choice: "

    read -r menu_input < /dev/tty
    menu_input=$(echo "$menu_input" | tr -d '\r')

    # Default (empty input) = All
    if [ -z "$menu_input" ]; then
        CATEGORY_FILTER="all"
    else
        CATEGORY_FILTER=""
        for tok in $menu_input; do
            case "$tok" in
                0) CATEGORY_FILTER="all"; break ;;
                1) CATEGORY_FILTER="$CATEGORY_FILTER,apps"   ;;
                2) CATEGORY_FILTER="$CATEGORY_FILTER,pkgs"   ;;
                3) CATEGORY_FILTER="$CATEGORY_FILTER,brew"   ;;
                4) CATEGORY_FILTER="$CATEGORY_FILTER,pip"    ;;
                5) CATEGORY_FILTER="$CATEGORY_FILTER,node"   ;;
                6) CATEGORY_FILTER="$CATEGORY_FILTER,langs"  ;;
                7) CATEGORY_FILTER="$CATEGORY_FILTER,system" ;;
                *) warn "Unknown choice: $tok" ;;
            esac
        done
        [ -z "$CATEGORY_FILTER" ] && CATEGORY_FILTER="all"
    fi
elif [ -z "$CATEGORY_FILTER" ]; then
    # --yes or --dry-run without --category defaults to all
    CATEGORY_FILTER="all"
fi

ACTIVE_CATEGORIES=",$CATEGORY_FILTER,"
log "Categories: $CATEGORY_FILTER"

# Filter entries to only the selected categories
WORK_ENTRIES=()
for entry in "${ALL_ENTRIES[@]}"; do
    TYPE=$(echo "$entry" | cut -d'|' -f4)
    _category_active "$TYPE" && WORK_ENTRIES+=("$entry")
done

WORK_TOTAL=${#WORK_ENTRIES[@]}

if [ "$WORK_TOTAL" -eq 0 ]; then
    warn "No items found for selected categories."
    exit 0
fi

[ "$DRY_RUN" = false ] \
    && header "Processing $WORK_TOTAL item(s)" \
    || header "DRY RUN — $WORK_TOTAL item(s) would be examined"

REMOVED=0
SKIPPED=0
NUM=0

for entry in "${WORK_ENTRIES[@]}"; do
    NUM=$((NUM + 1))
    DISPLAY=$(echo "$entry" | cut -d'|' -f2)
    ID=$(echo "$entry"      | cut -d'|' -f3)
    TYPE=$(echo "$entry"    | cut -d'|' -f4)
    DETAIL=$(echo "$entry"  | cut -d'|' -f5)

    sep
    printf "\n  [%d/%d] %s  [%s]\n" "$NUM" "$WORK_TOTAL" "$DISPLAY" "$TYPE"
    printf "  Path/ID: %s\n" "$DETAIL"

    case "$TYPE" in

    app)
        BUNDLE="$DETAIL"
        ARTIFACTS=("$BUNDLE")
        while IFS= read -r art; do [ -n "$art" ] && ARTIFACTS+=("$art")
        done < <(find_artifacts "$ID" "$DISPLAY")

        AGENT_SPECS=()
        while IFS= read -r aspec; do [ -n "$aspec" ] && AGENT_SPECS+=("$aspec")
        done < <(find_agents "$ID")

        FOUND_LIST=""
        for p in "${ARTIFACTS[@]}"; do
            { [ -e "$p" ] || [ -L "$p" ]; } && FOUND_LIST="${FOUND_LIST}
    $p"
        done
        for aspec in "${AGENT_SPECS[@]+"${AGENT_SPECS[@]}"}"; do
            aplist="${aspec##*|}"
            [ -e "$aplist" ] && FOUND_LIST="${FOUND_LIST}
    $aplist  [agent/daemon]"
        done
        [ -n "$FOUND_LIST" ] \
            && printf "  Artifacts:%s\n" "$FOUND_LIST" \
            || printf "  (no Library artifacts found)\n"

        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        _kill_bundle "$BUNDLE"
        for aspec in "${AGENT_SPECS[@]+"${AGENT_SPECS[@]}"}"; do
            _rm_agent "${aspec%%|*}" "${aspec##*|}"
        done
        for art in "${ARTIFACTS[@]}"; do _rm "$art"; done
        ;;

    pkg)
        PKG_VER=$(pkgutil --pkg-info "$ID" 2>/dev/null | awk '/^version:/{print $2}')
        printf "  Version: %s\n" "$PKG_VER"
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        _rm_pkg "$ID"
        ;;

    brew_formula)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  brew uninstall --formula %s\n" "$ID"
        else
            sudo -u "$REAL_USER" "$_BREW" uninstall --formula "$ID" 2>&1 \
                | while IFS= read -r l; do log "$l"; done
        fi
        ;;

    brew_cask)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  brew uninstall --cask %s\n" "$ID"
        else
            sudo -u "$REAL_USER" "$_BREW" uninstall --cask "$ID" 2>&1 \
                | while IFS= read -r l; do log "$l"; done
        fi
        ;;

    pip)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  pip3 uninstall --yes %s\n" "$ID"
        else
            sudo -u "$REAL_USER" "$_PIP" uninstall --yes "$ID" 2>&1 \
                | while IFS= read -r l; do log "$l"; done
        fi
        ;;

    pipx)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  pipx uninstall %s\n" "$ID"
        else
            "$_PIPX" uninstall "$ID" 2>&1 | while IFS= read -r l; do log "$l"; done
        fi
        ;;

    npm)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  npm uninstall -g %s\n" "$ID"
        else
            "$_NPM" uninstall -g "$ID" 2>&1 | while IFS= read -r l; do log "$l"; done
        fi
        ;;

    nvm|langdir|gobin|cargo|rustup)
        printf "  Directory: %s\n" "$DETAIL"
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        _rm "$DETAIL"
        ;;

    kext)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  kextunload -b %s\n" "$ID"
            printf "    [DRY]  rm -rf  %s\n" "$DETAIL"
        else
            kextunload -b "$ID" 2>/dev/null || true
            _rm "$DETAIL"
        fi
        ;;

    sysext)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        if [ "$DRY_RUN" = true ]; then
            printf "    [DRY]  systemextensionsctl uninstall %s\n" "$ID"
        else
            systemextensionsctl uninstall "$ID" 2>/dev/null \
                && ok "  Uninstalled system extension: $ID" \
                || warn "  systemextensionsctl uninstall failed for $ID"
        fi
        ;;

    agent)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        _rm_agent "gui/$REAL_UID/$ID" "$DETAIL"
        ;;

    daemon)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        _rm_agent "system/$ID" "$DETAIL"
        ;;

    helper)
        confirm_item || { log "Skipped: $DISPLAY"; SKIPPED=$((SKIPPED+1)); continue; }
        _rm "$DETAIL"
        ;;

    esac

    REMOVED=$((REMOVED + 1))
    [ "$DRY_RUN" = false ] && ok "[$DISPLAY] Done"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "SUMMARY"
log "Category:         $CATEGORY_FILTER"
log "Items discovered: $TOTAL  |  In category: $WORK_TOTAL"
if [ "$DRY_RUN" = true ]; then
    log "DRY RUN — no changes made"
else
    log "Removed: $REMOVED  |  Skipped: $SKIPPED"
    [ "$REMOVED" -gt 0 ] && echo "" && \
        echo "  Some changes require logout/login to fully take effect."
fi
log "Log: $LOG"
echo ""
