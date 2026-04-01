#!/bin/bash
# ==============================================================================
# OPTIMIZATIONS — macOS 26.4 / Apple M5 Max
# 109 individually confirmed system preferences and tuning settings.
#
# USAGE:
#   sudo ./optimizations.sh [OPTIONS]
#
# OPTIONS:
#   --dry-run          Show what would change; make no changes
#   --yes              Skip all confirmation prompts; apply everything
#   --list             List all optimization keys and descriptions, then exit
#   --group  g1,g2     Process only these groups (comma-separated)
#   --skip   g1,k1     Skip these groups or individual keys (comma-separated)
#   --item   k1,k2     Process only these individual keys (comma-separated)
#   --backup           Snapshot all current values to a restore script before applying
#
# CONFIRMATION (default — interactive without --yes or --dry-run):
#   Each optimization is shown with its current value and new value.
#   Prompt: [y] apply  [n] skip  [a] apply all remaining  [q] quit
#
# EXAMPLES:
#   ./optimizations.sh --dry-run                         # preview all
#   sudo ./optimizations.sh --yes --group trackpad       # apply trackpad group
#   sudo ./optimizations.sh --item touchid_sudo          # single item
#   sudo ./optimizations.sh --group input,power          # two groups
#   sudo ./optimizations.sh --skip dock_strip,wallpaper_black
#   ./optimizations.sh --list                            # show all keys
#
# GROUPS:
#   input        Keyboard repeat, press-and-hold, Touch ID sudo
#   trackpad     Tracking speed, tap-to-click, scroll, gestures
#   spotlight    Indexing scope, categories, Siri suggestions
#   animations   Window/scroll/motion/blur effects
#   dock         Auto-hide, animations, strip, hot corners
#   finder       Hidden files, extensions, path bar, panels, iCloud
#   ui           Green button, widgets, shortcuts, clock, wallpaper
#   power        AC/battery sleep, clamshell, Power Nap, standby
#   network      TCP tuning, sysctl, Chrome DoH, DNS flush
#   updates      Apple SU, Chrome Keystone, Edge updater, AirDrop, Handoff
#   security     SMB guest, SSH, Remote Events, Gatekeeper, TCC, mDNS, pfctl
# ==============================================================================

set -uo pipefail

# ==============================================================================
# USER CONFIGURATION — edit these values before running
# ==============================================================================

# Timezone applied by the 'timezone' optimization.
# Run `sudo systemsetup -listtimezones` to see all valid values.
MACHETE_TIMEZONE="Australia/Perth"

# Computer name applied by the 'computer_name' optimization.
# Sets ComputerName, LocalHostName, and HostName.
MACHETE_COMPUTER_NAME="M5"

# Dock apps pinned by the 'dock_strip' optimization.
# Each entry is an absolute path to a .app bundle.
MACHETE_DOCK_APPS=(
    "/System/Applications/Utilities/Terminal.app"
    "/System/Applications/System Settings.app"
)

# ==============================================================================
# END USER CONFIGURATION
# ==============================================================================

# ---------------------------------------------------------------------------
# Paths & arguments
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/optimizations-$(date +%Y%m%d-%H%M%S).log"

DRY_RUN=false
YES_ALL=false
LIST_ONLY=false
BACKUP_MODE=false
GROUP_FILTER=""
ITEM_FILTER=""
SKIP_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true ;;
        --yes)      YES_ALL=true ;;
        --list)     LIST_ONLY=true ;;
        --group)    GROUP_FILTER="$2"; shift ;;
        --item)     ITEM_FILTER="$2"; shift ;;
        --skip)              SKIP_FILTER="$2"; shift ;;
        --backup)            BACKUP_MODE=true ;;
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
# Root check (not needed for --dry-run or --list)
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ] && [ "$LIST_ONLY" = false ]; then
    err "Must be run as root: sudo ./optimizations.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Real user detection — sudo-safe defaults writes
# ---------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER=$(logname 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER="$USER"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "$(id -u)")

# Write defaults as the real (non-root) user
dfw() { sudo -u "$REAL_USER" defaults "$@"; }

# ---------------------------------------------------------------------------
# OPTIMIZATION REGISTRY
# Format: "KEY|GROUP|DESCRIPTION"
# Ordered exactly as executed. 110 entries.
# ---------------------------------------------------------------------------
OPTIM_LIST=(
    # ── input ───────────────────────────────────────────────────────────────
    "key_repeat_rate|input|Key repeat rate → 1 (~15ms, fastest)"
    "key_repeat_delay|input|Initial key repeat delay → 10 (~150ms before repeat starts)"
    "press_and_hold|input|Disable press-and-hold accent picker (unblocks key repeat in all apps)"
    "touchid_sudo|input|Enable Touch ID for sudo (/etc/pam.d/sudo_local)"
    # ── trackpad ────────────────────────────────────────────────────────────
    "trackpad_speed|trackpad|Trackpad tracking speed → 3.0 (maximum)"
    "mouse_speed|trackpad|Mouse tracking speed → 3.0 (maximum)"
    "spring_load|trackpad|Spring-loading delay → 0.1s (folders open instantly on drag-hover)"
    "tap_to_click|trackpad|Enable tap-to-click (user domain + currentHost + BT trackpad)"
    "tap_to_drag|trackpad|Enable tap-to-drag (user domain + currentHost)"
    "three_finger_drag|trackpad|Disable 3-finger drag (conflicts with MiddleClick)"
    "three_finger_tap|trackpad|Disable 3-finger tap Look Up gesture"
    "natural_scroll|trackpad|Natural scroll OFF — traditional scroll direction (wheel down = page down)"
    # ── spotlight ───────────────────────────────────────────────────────────
    "spotlight_boot_volume|spotlight|Ensure Spotlight indexing enabled on / (required for app search)"
    "spotlight_external_volumes|spotlight|Disable Spotlight indexing on all non-boot volumes"
    "spotlight_exclusions|spotlight|Clear overly broad Spotlight ExclusionPaths"
    "spotlight_categories|spotlight|Spotlight shows: Apps + Calculator + System Settings only"
    "spotlight_siri|spotlight|Disable Siri suggestions in Spotlight"
    "spotlight_pref_rules|spotlight|Purge Spotlight EnabledPreferenceRules for removed apps"
    # ── animations ──────────────────────────────────────────────────────────
    "window_animations|animations|Disable window open/close animations globally"
    "window_resize_time|animations|Window resize animation → instant (0.001s)"
    "scroll_animation|animations|Disable smooth scroll animation (instant jump)"
    "rubber_band|animations|Disable rubber-band overscroll bounce"
    "reduce_motion|animations|Enable Reduce Motion (removes space-switch swoosh and zoom)"
    "desktop_tinting|animations|Disable desktop tinting (wallpaper color bleeding into UI chrome)"
    "menubar_blur|animations|Disable menu bar blur compositing (~15-20% WindowServer CPU saving)"
    # ── dock ────────────────────────────────────────────────────────────────
    "dock_autohide|dock|Enable Dock auto-hide"
    "dock_autohide_delay|dock|Dock auto-hide delay → 0 (appear instantly)"
    "dock_autohide_animation|dock|Dock show/hide animation → 0 (instant)"
    "dock_launch_animation|dock|Disable Dock icon bounce on app launch"
    "dock_no_bounce|dock|Disable Dock icon bounce notifications"
    "dock_expose_animation|dock|Mission Control / Exposé animation → instant"
    "dock_minimize_to_app|dock|Minimize windows into app icon (not separate Dock slot)"
    "dock_minimize_effect|dock|Minimize effect → scale (fastest)"
    "dock_space_animation|dock|Disable space-switching swoosh animation"
    "dock_launchpad_animation|dock|Disable Launchpad show/hide animation"
    "dock_strip|dock|Strip Dock to configured apps only, disable show-recents (see MACHETE_DOCK_APPS)"
    "hot_corners|dock|Disable all four hot corners"
    # ── finder ──────────────────────────────────────────────────────────────
    "finder_animations|finder|Disable all Finder animations and window zoom animation"
    "finder_hidden_files|finder|Show all hidden files and dotfiles"
    "finder_extensions|finder|Always show file extensions (never hide .app .sh .py etc.)"
    "finder_path_bar|finder|Show path bar (full folder path at bottom of Finder window)"
    "finder_status_bar|finder|Show status bar (item count + disk space used/free)"
    "finder_posix_title|finder|Show full POSIX path in Finder window title"
    "finder_no_ext_warning|finder|No warning when changing a file extension"
    "finder_no_trash_warning|finder|No warning when emptying Trash"
    "finder_search_current|finder|Search current folder by default (not entire Mac)"
    "finder_folders_first|finder|Folders sort before files in list view and on desktop"
    "finder_home_default|finder|New Finder window opens to home folder"
    "finder_list_view|finder|Default view → list view (all windows)"
    "finder_list_view_columns|finder|List view: show name, size, date modified, kind columns"
    "finder_list_view_icon_size|finder|List view: icon size 16px, text size 13pt, relative dates ON"
    "finder_toolbar|finder|Show Finder toolbar (TB Is Shown)"
    "finder_sidebar|finder|Show Finder sidebar"
    "finder_preview_pane|finder|Show preview pane (right side — file details without opening)"
    "finder_tab_bar|finder|Show tab bar (enables window tabs in all new Finder windows)"
    "finder_quicklook_text|finder|Allow text selection in Quick Look (Cmd+Space preview)"
    "finder_desktop_icons|finder|Show hard drives, external drives, removable media on desktop"
    "finder_save_panel|finder|Expand Save panel by default (never show minimal one-liner)"
    "finder_print_panel|finder|Expand Print panel by default"
    "finder_save_to_disk|finder|Save new documents to disk by default (not iCloud)"
    "finder_no_icloud|finder|Remove iCloud Drive from Finder sidebar and Go menu"
    "finder_terminal_service|finder|Enable 'New Terminal at Folder' and 'New Terminal Tab at Folder' Services"
    "ds_store_network|finder|Disable .DS_Store creation on network volumes"
    "ds_store_usb|finder|Disable .DS_Store creation on USB/external volumes"
    "ds_store_remove|finder|Remove all existing .DS_Store files from home directory"
    # ── ui ──────────────────────────────────────────────────────────────────
    "green_button_maximize|ui|Green button → maximize instead of full-screen"
    "maximize_shortcut|ui|Ctrl+Cmd+M = maximize shortcut (global, all apps)"
    "widgets_disable|ui|Disable all widgets (clear WidgetAllowList → ~500 MB RAM freed)"
    "screenshots|ui|Ensure Cmd+Shift+3/4/5 screenshot shortcuts are enabled"
    "spotlight_shortcut|ui|Ensure Cmd+Space app launcher shortcut is enabled"
    "controlcenter_cleanup|ui|Remove orphaned Control Center items (Siri, AirDrop, TimeMachine, Weather)"
    "wallpaper_black|ui|Set solid black wallpaper (eliminates WallpaperAerialsExtension ~131 MB)"
    "timezone|ui|Set timezone (see MACHETE_TIMEZONE in USER CONFIGURATION block)"
    "clock_24hr|ui|Force 24-hour clock system-wide"
    "clock_iso_date|ui|ISO 8601 date format: yyyy-MM-dd at all ICU length levels"
    "clock_seconds|ui|Show seconds in menu bar clock"
    "clock_menubar_format|ui|Menu bar clock format → yyyy-MM-dd HH:mm:ss"
    "computer_name|ui|Set computer name (see MACHETE_COMPUTER_NAME in USER CONFIGURATION block)"
    # ── power ───────────────────────────────────────────────────────────────
    "power_mode_auto|power|AC power mode → Auto (full boost on demand, saves at idle)"
    "power_display_sleep_ac|power|AC display sleep → 5 minutes"
    "power_system_sleep_ac|power|AC system sleep → 10 minutes"
    "power_clamshell|power|Clamshell mode: continue processing with lid closed (AC)"
    "power_nap_ac|power|Disable Power Nap on AC (nothing left to wake up for)"
    "power_disk_sleep_ac|power|AC disk sleep → 10 minutes"
    "power_display_sleep_bat|power|Battery display sleep → 2 minutes"
    "power_system_sleep_bat|power|Battery system sleep → 5 minutes"
    "power_standby_bat|power|Disable standby on battery (stops background wake cycle)"
    "power_nap_bat|power|Disable Power Nap on battery"
    # ── network ─────────────────────────────────────────────────────────────
    "tcp_socket_buffer|network|Max socket buffer → 16 MB (throughput on fast networks)"
    "tcp_send_recv_space|network|TCP send/receive space → 1 MB per connection"
    "tcp_somaxconn|network|Listen backlog queue → 2048 (dev servers under burst load)"
    "sysctl_perf|network|Kernel: maxvnodes=750k (vnode cache, more open dirs/files)"
    "sysctl_persist|network|Persist all sysctl settings via /etc/sysctl.conf"
    "chrome_doh|network|Disable Chrome DNS-over-HTTPS (fixes ERR_ADDRESS_UNREACHABLE on IPv4-only)"
    "dns_flush|network|Flush DNS cache (dscacheutil + mDNSResponder)"
    # ── updates ─────────────────────────────────────────────────────────────
    "apple_autoupdate|updates|Disable Apple Software Update auto-check/download (user + system domain)"
    "chrome_keystone|updates|Disable Chrome Keystone updater (all 4 agents/daemons)"
    "edge_updater|updates|Disable Microsoft Edge updater"
    "airdrop|updates|Disable AirDrop"
    "handoff_continuity|updates|Disable Handoff and Continuity"
    "chrome_crashpad|updates|Create Chrome Crashpad settings.dat (suppress log error)"
    # ── security ────────────────────────────────────────────────────────────
    "smb_guest|security|Disable SMB guest access (shares require authentication)"
    "ssh_server|security|Disable SSH server / sshd inbound (outbound SSH unaffected)"
    "remote_apple_events|security|Disable Remote Apple Events (remote AppleScript execution)"
    "gatekeeper|security|Disable Gatekeeper (allow unsigned binaries on dev machine)"
    "mdns_multicast|security|Suppress mDNS multicast (machine invisible on LAN)"
    "hosts_telemetry|security|Null-route 11 Apple telemetry domains in /etc/hosts"
    "pfctl_telemetry|security|pfctl anchor: block outbound telemetry at kernel level"
    "alf_firewall|security|Enable ALF firewall with stealth mode (block unsolicited inbound)"
)

TOTAL_ITEMS=${#OPTIM_LIST[@]}

# ---------------------------------------------------------------------------
# Build work list (filter by --group / --item / --skip)
# ---------------------------------------------------------------------------
build_work_list() {
    WORK_LIST=()
    local idx=0
    for entry in "${OPTIM_LIST[@]}"; do
        idx=$((idx + 1))
        local key group desc
        key=$(echo "$entry"  | cut -d'|' -f1)
        group=$(echo "$entry" | cut -d'|' -f2)
        desc=$(echo "$entry"  | cut -d'|' -f3)

        # --item filter
        if [ -n "$ITEM_FILTER" ]; then
            if ! echo ",$ITEM_FILTER," | grep -qF ",$key,"; then continue; fi
        fi

        # --group filter
        if [ -n "$GROUP_FILTER" ]; then
            if ! echo ",$GROUP_FILTER," | grep -qF ",$group,"; then continue; fi
        fi

        # --skip filter (matches both key and group)
        if [ -n "$SKIP_FILTER" ]; then
            if echo ",$SKIP_FILTER," | grep -qF ",$key,"; then continue; fi
            if echo ",$SKIP_FILTER," | grep -qF ",$group,"; then continue; fi
        fi

        WORK_LIST+=("$idx|$key|$group|$desc")
    done
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = true ]; then
    header "OPTIMIZATIONS — $TOTAL_ITEMS items across 11 groups"
    current_group=""
    idx=0
    for entry in "${OPTIM_LIST[@]}"; do
        idx=$((idx + 1))
        key=$(echo "$entry"   | cut -d'|' -f1)
        group=$(echo "$entry" | cut -d'|' -f2)
        desc=$(echo "$entry"  | cut -d'|' -f3)
        if [ "$group" != "$current_group" ]; then
            echo ""
            echo "  ── $group ──"
            current_group="$group"
        fi
        printf "  %3d  %-35s %s\n" "$idx" "$key" "$desc"
    done
    echo ""
    echo "  Total: $TOTAL_ITEMS  |  Usage: sudo ./optimizations.sh --yes --group <group>"
    exit 0
fi

header "OPTIMIZATIONS — macOS $(sw_vers -productVersion)"
log "Log:     $LOG"
log "Dry run: $DRY_RUN"
log "Yes all: $YES_ALL"
log "User:    $REAL_USER (home: $REAL_HOME)"

build_work_list
log "Items to process: ${#WORK_LIST[@]} of $TOTAL_ITEMS"

# ---------------------------------------------------------------------------
# Confirmation engine — same y/n/a/q pattern as debloat.sh
# Returns 0 = proceed, 1 = skip
# ---------------------------------------------------------------------------
_accept_all=false
SPOTLIGHT_CHANGED=false   # set true when any spotlight_* item is applied

confirm_item() {
    local number="$1" key="$2" desc="$3" before_val="$4" after_val="$5"

    if [ "$DRY_RUN" = true ] || [ "$YES_ALL" = true ] || [ "$_accept_all" = true ]; then
        return 0
    fi

    echo ""
    sep
    printf "  [%d/%d] %s\n" "$number" "${#WORK_LIST[@]}" "$desc"
    printf "  Key:    %s\n" "$key"
     [ -n "$before_val" ] && printf "  Before: %s\n" "$before_val"
     [ -n "$after_val"  ] && printf "  After:  %s\n" "$after_val"
     printf "  Apply? [y/n/a/q]: "

     local ans ans_lower
     read -r ans < /dev/tty
     ans_lower=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
     case "$ans_lower" in
         y|yes)          return 0 ;;
         n|no)           return 1 ;;
         a|all)          _accept_all=true; return 0 ;;
         q|quit|exit)
             log "Quit at item $number ($key). No further changes."
             echo ""
             echo "  Quit. Flushing preferences written so far..."
             _flush_prefs
            exit 0
            ;;
        *)
            warn "Unrecognised input — skipping $key"
            return 1
            ;;
    esac
}

# Print a dry-run line (no prompt needed)
dry_item() {
    local number="$1" key="$2" desc="$3" before_val="$4" after_val="$5"
    printf "  [%3d/%d] %-35s | Before: %-30s → After: %s\n" \
        "$number" "${#WORK_LIST[@]}" "$key" "${before_val:-(not set)}" "$after_val"
}

# ---------------------------------------------------------------------------
# APPLY FUNCTIONS — one per optimization key
# Each: reads current value, calls confirm_item, applies if confirmed
# ---------------------------------------------------------------------------

_run_item() {
    local num="$1" key="$2" desc="$3"
    shift 3
    # Remaining positional args: before after (passed by apply_ function)
    local before="${1:-}" after="${2:-}"

    if [ "$DRY_RUN" = true ]; then
        dry_item "$num" "$key" "$desc" "$before" "$after"
        return 0
    fi

    confirm_item "$num" "$key" "$desc" "$before" "$after" || return 0
}

# ── INPUT ──────────────────────────────────────────────────────────────────

apply_key_repeat_rate() {
    local num="$1" desc="$2"
    local before after="1"
    before=$(dfw read NSGlobalDomain KeyRepeat 2>/dev/null || echo "default (6)")
    _run_item "$num" "key_repeat_rate" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain KeyRepeat -int 1
    ok "KeyRepeat = 1  (rollback: defaults delete NSGlobalDomain KeyRepeat)"
}

apply_key_repeat_delay() {
    local num="$1" desc="$2"
    local before after="10"
    before=$(dfw read NSGlobalDomain InitialKeyRepeat 2>/dev/null || echo "default (25)")
    _run_item "$num" "key_repeat_delay" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain InitialKeyRepeat -int 10
    ok "InitialKeyRepeat = 10  (rollback: defaults delete NSGlobalDomain InitialKeyRepeat)"
}

apply_press_and_hold() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read NSGlobalDomain ApplePressAndHoldEnabled 2>/dev/null || echo "default (true)")
    _run_item "$num" "press_and_hold" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain ApplePressAndHoldEnabled -bool false
    ok "PressAndHold = false  (rollback: defaults delete NSGlobalDomain ApplePressAndHoldEnabled)"
}

apply_touchid_sudo() {
    local num="$1" desc="$2"
    local PAM_FILE="/etc/pam.d/sudo_local"
    local PAM_LINE="auth       sufficient     pam_tid.so"
    local before after="pam_tid.so added to $PAM_FILE"

    if [ -f "$PAM_FILE" ] && grep -q "pam_tid.so" "$PAM_FILE" 2>/dev/null; then
        before="already enabled"
    else
        before="not enabled"
    fi
    _run_item "$num" "touchid_sudo" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0

    if ! grep -q "pam_tid.so" "$PAM_FILE" 2>/dev/null; then
        # Create or prepend to sudo_local
        if [ ! -f "$PAM_FILE" ]; then
            printf "# sudo_local: managed by optimizations.sh\n%s\n" "$PAM_LINE" \
                | sudo tee "$PAM_FILE" > /dev/null
        else
            local tmp
            tmp=$(mktemp)
            # Insert after first non-comment line or at top
            awk -v line="$PAM_LINE" '
                !inserted && /^auth/ { print line; inserted=1 }
                { print }
                END { if (!inserted) print line }
            ' "$PAM_FILE" > "$tmp"
            sudo cp "$tmp" "$PAM_FILE"
            rm -f "$tmp"
        fi
        ok "Touch ID sudo enabled in $PAM_FILE  (rollback: remove 'pam_tid.so' line from $PAM_FILE)"
    else
        ok "Touch ID sudo already active in $PAM_FILE"
    fi
}

# ── TRACKPAD ───────────────────────────────────────────────────────────────

apply_trackpad_speed() {
    local num="$1" desc="$2"
    local before after="3.0"
    before=$(dfw read NSGlobalDomain com.apple.trackpad.scaling 2>/dev/null || echo "default")
    _run_item "$num" "trackpad_speed" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain com.apple.trackpad.scaling -float 3.0
    ok "trackpad.scaling = 3.0"
}

apply_mouse_speed() {
    local num="$1" desc="$2"
    local before after="3.0"
    before=$(dfw read NSGlobalDomain com.apple.mouse.scaling 2>/dev/null || echo "default")
    _run_item "$num" "mouse_speed" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain com.apple.mouse.scaling -float 3.0
    ok "mouse.scaling = 3.0"
}

apply_spring_load() {
    local num="$1" desc="$2"
    local before after="0.1"
    before=$(dfw read NSGlobalDomain com.apple.springing.delay 2>/dev/null || echo "default (0.5)")
    _run_item "$num" "spring_load" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain com.apple.springing.delay -float 0.1
    dfw write NSGlobalDomain com.apple.springing.enabled -bool true
    ok "springing.delay = 0.1"
}

apply_tap_to_click() {
    local num="$1" desc="$2"
    local before after="true (both domains + currentHost)"
    before=$(dfw read com.apple.AppleMultitouchTrackpad Clicking 2>/dev/null || echo "default (false)")
    _run_item "$num" "tap_to_click" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.AppleMultitouchTrackpad Clicking -bool true
    dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
    dfw -currentHost write com.apple.AppleMultitouchTrackpad Clicking -bool true
    dfw -currentHost write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
    dfw write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
    dfw -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
    ok "Tap-to-click enabled"
}

apply_tap_to_drag() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.AppleMultitouchTrackpad Dragging 2>/dev/null || echo "default (false)")
    _run_item "$num" "tap_to_drag" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.AppleMultitouchTrackpad Dragging -bool true
    dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool true
    dfw -currentHost write com.apple.AppleMultitouchTrackpad Dragging -bool true
    dfw -currentHost write com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool true
    ok "Tap-to-drag enabled"
}

apply_three_finger_drag() {
    local num="$1" desc="$2"
    local before after="false (MiddleClick uses 3 fingers)"
    before=$(dfw read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag 2>/dev/null || echo "default")
    _run_item "$num" "three_finger_drag" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool false
    dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool false
    dfw -currentHost write NSGlobalDomain com.apple.trackpad.threeFingerDragGesture -bool false
    dfw write com.apple.universalaccess trackpadThreeFingerDragEnabled -bool false 2>/dev/null || true
    ok "3-finger drag disabled"
}

apply_three_finger_tap() {
    local num="$1" desc="$2"
    local before after="0 (disabled)"
    before=$(dfw read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture 2>/dev/null || echo "default (2)")
    _run_item "$num" "three_finger_tap" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture -int 0
    dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerTapGesture -int 0
    ok "3-finger tap Look Up disabled"
}

apply_natural_scroll() {
    local num="$1" desc="$2"
    local before after="false (traditional — wheel down = page down)"
    before=$(defaults read NSGlobalDomain com.apple.swipescrolldirection 2>/dev/null || echo "default (1=natural)")
    _run_item "$num" "natural_scroll" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain com.apple.swipescrolldirection -bool false
    dfw write com.apple.AppleMultitouchTrackpad TrackpadScroll -bool true
    dfw write com.apple.AppleMultitouchTrackpad TrackpadHorizScroll -int 1
    dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadScroll -bool true
    dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadHorizScroll -int 1
    dfw -currentHost write NSGlobalDomain com.apple.swipescrolldirection -bool false
    ok "Scroll direction = traditional (natural scroll OFF)"
}

# ── SPOTLIGHT ──────────────────────────────────────────────────────────────

apply_spotlight_boot_volume() {
    local num="$1" desc="$2"
    local before after="enabled on /"
    before=$(mdutil -s / 2>/dev/null | tr -d '\n' || echo "unknown")
    _run_item "$num" "spotlight_boot_volume" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    if echo "$before" | grep -q "disabled"; then
        sudo mdutil -i on / 2>/dev/null || true
        ok "Spotlight indexing enabled on /"
    else
        ok "Spotlight indexing already enabled on /"
    fi
}

apply_spotlight_external_volumes() {
    local num="$1" desc="$2"
    local before="(scanning)" after="indexing OFF on non-boot volumes"
    _run_item "$num" "spotlight_external_volumes" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    local count=0
    while IFS= read -r vol; do
        case "$vol" in /System/Volumes/*) continue ;; esac
        sudo mdutil -i off "$vol" 2>/dev/null && count=$((count+1)) || true
    done < <(mount | grep -E "apfs|hfs" | awk '{print $3}' | grep -v "^/$")
    ok "Spotlight disabled on $count non-boot volume(s)"
}

apply_spotlight_exclusions() {
    local num="$1" desc="$2"
    local before after="ExclusionPaths cleared"
    before=$(dfw read com.apple.Spotlight ExclusionPaths 2>/dev/null | head -3 || echo "(none)")
    _run_item "$num" "spotlight_exclusions" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    dfw delete com.apple.Spotlight ExclusionPaths 2>/dev/null || true
    ok "Spotlight ExclusionPaths cleared"
}

apply_spotlight_categories() {
    local num="$1" desc="$2"
    local before="(current orderedItems)" after="Apps + Calculator + Settings only"
    _run_item "$num" "spotlight_categories" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    dfw write com.apple.Spotlight orderedItems -array \
        '{ enabled = 1; name = APPLICATIONS; }' \
        '{ enabled = 1; name = "MENU_EXPRESSION"; }' \
        '{ enabled = 1; name = "SYSTEM_PREFS"; }' \
        '{ enabled = 0; name = "MENU_WEBSEARCH"; }' \
        '{ enabled = 0; name = "MENU_SPOTLIGHT_SUGGESTIONS"; }' \
        '{ enabled = 0; name = BOOKMARKS; }' \
        '{ enabled = 0; name = MUSIC; }' \
        '{ enabled = 0; name = MOVIES; }' \
        '{ enabled = 0; name = FONTS; }' \
        '{ enabled = 0; name = MESSAGES; }' \
        '{ enabled = 0; name = IMAGES; }' \
        '{ enabled = 0; name = DOCUMENTS; }' \
        '{ enabled = 0; name = DIRECTORIES; }' \
        '{ enabled = 0; name = PRESENTATIONS; }' \
        '{ enabled = 0; name = SPREADSHEETS; }' \
        '{ enabled = 0; name = PDF; }' \
        '{ enabled = 0; name = CONTACT; }' \
        '{ enabled = 0; name = "EVENT_TODO"; }' \
        '{ enabled = 0; name = "MENU_OTHER"; }' \
        '{ enabled = 0; name = "MENU_DEFINITION"; }' \
        '{ enabled = 0; name = SOURCE; }'
    launchctl kickstart -k "gui/$REAL_UID/com.apple.Spotlight" 2>/dev/null || \
        killall Spotlight 2>/dev/null || true
    ok "Spotlight categories set to Apps + Calculator + Settings"
}

apply_spotlight_siri() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read com.apple.Spotlight SiriSuggestionsEnabled 2>/dev/null || echo "default (true)")
    _run_item "$num" "spotlight_siri" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    dfw write com.apple.Spotlight SiriSuggestionsEnabled -bool false
    dfw write com.apple.Spotlight ShowSiriSuggestionsInSpotlight -bool false
    dfw write com.apple.lookup.shared LookupSuggestionsDisabled -bool true 2>/dev/null || true
    ok "Siri suggestions in Spotlight disabled"
}

apply_spotlight_pref_rules() {
    local num="$1" desc="$2"
    local before after="EnabledPreferenceRules deleted"
    before=$(dfw read com.apple.Spotlight EnabledPreferenceRules 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    before="$before entries"
    _run_item "$num" "spotlight_pref_rules" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    dfw delete com.apple.Spotlight EnabledPreferenceRules 2>/dev/null || true
    ok "Spotlight EnabledPreferenceRules purged"
}

# ── ANIMATIONS ─────────────────────────────────────────────────────────────

apply_window_animations() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read NSGlobalDomain NSAutomaticWindowAnimationsEnabled 2>/dev/null || echo "default (true)")
    _run_item "$num" "window_animations" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
    ok "NSAutomaticWindowAnimationsEnabled = false"
}

apply_window_resize_time() {
    local num="$1" desc="$2"
    local before after="0.001"
    before=$(dfw read NSGlobalDomain NSWindowResizeTime 2>/dev/null || echo "default (0.2)")
    _run_item "$num" "window_resize_time" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain NSWindowResizeTime -float 0.001
    ok "NSWindowResizeTime = 0.001"
}

apply_scroll_animation() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read NSGlobalDomain NSScrollAnimationEnabled 2>/dev/null || echo "default (true)")
    _run_item "$num" "scroll_animation" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain NSScrollAnimationEnabled -bool false
    ok "NSScrollAnimationEnabled = false"
}

apply_rubber_band() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read -g NSScrollViewRubberbanding 2>/dev/null || echo "default (true)")
    _run_item "$num" "rubber_band" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write -g NSScrollViewRubberbanding -bool false
    ok "NSScrollViewRubberbanding = false"
}

apply_reduce_motion() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.universalaccess reduceMotion 2>/dev/null || echo "default (false)")
    _run_item "$num" "reduce_motion" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.universalaccess reduceMotion -bool true
    ok "reduceMotion = true"
}

apply_desktop_tinting() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read NSGlobalDomain AppleReduceDesktopTinting 2>/dev/null || echo "default (false)")
    _run_item "$num" "desktop_tinting" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain AppleReduceDesktopTinting -bool true
    ok "AppleReduceDesktopTinting = true"
}

apply_menubar_blur() {
    local num="$1" desc="$2"
    local before after="false (transparent/black, zero compositing)"
    before=$(dfw read NSGlobalDomain SLSMenuBarUseBlurredAppearance 2>/dev/null || echo "default (true)")
    _run_item "$num" "menubar_blur" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain SLSMenuBarUseBlurredAppearance -bool false
    ok "SLSMenuBarUseBlurredAppearance = false"
}

# ── DOCK ───────────────────────────────────────────────────────────────────

apply_dock_autohide() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.dock autohide 2>/dev/null || echo "default (false)")
    _run_item "$num" "dock_autohide" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock autohide -bool true
    ok "Dock autohide = true"
}

apply_dock_autohide_delay() {
    local num="$1" desc="$2"
    local before after="0"
    before=$(dfw read com.apple.dock autohide-delay 2>/dev/null || echo "default (0.5)")
    _run_item "$num" "dock_autohide_delay" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock autohide-delay -float 0
    ok "autohide-delay = 0"
}

apply_dock_autohide_animation() {
    local num="$1" desc="$2"
    local before after="0"
    before=$(dfw read com.apple.dock autohide-time-modifier 2>/dev/null || echo "default (0.5)")
    _run_item "$num" "dock_autohide_animation" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock autohide-time-modifier -float 0
    ok "autohide-time-modifier = 0"
}

apply_dock_launch_animation() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read com.apple.dock launchanim 2>/dev/null || echo "default (true)")
    _run_item "$num" "dock_launch_animation" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock launchanim -bool false
    ok "launchanim = false"
}

apply_dock_no_bounce() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.dock no-bouncing 2>/dev/null || echo "default (false)")
    _run_item "$num" "dock_no_bounce" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock no-bouncing -bool true
    ok "no-bouncing = true"
}

apply_dock_expose_animation() {
    local num="$1" desc="$2"
    local before after="0"
    before=$(dfw read com.apple.dock expose-animation-duration 2>/dev/null || echo "default (0.1)")
    _run_item "$num" "dock_expose_animation" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock expose-animation-duration -float 0
    ok "expose-animation-duration = 0"
}

apply_dock_minimize_to_app() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.dock minimize-to-application 2>/dev/null || echo "default (false)")
    _run_item "$num" "dock_minimize_to_app" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock minimize-to-application -bool true
    ok "minimize-to-application = true"
}

apply_dock_minimize_effect() {
    local num="$1" desc="$2"
    local before after="scale"
    before=$(dfw read com.apple.dock mineffect 2>/dev/null || echo "default (genie)")
    _run_item "$num" "dock_minimize_effect" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock mineffect -string "scale"
    ok "mineffect = scale"
}

apply_dock_space_animation() {
    local num="$1" desc="$2"
    local before after="true (animation OFF)"
    before=$(dfw read com.apple.dock workspaces-swoosh-animation-off 2>/dev/null || echo "default (false)")
    _run_item "$num" "dock_space_animation" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock workspaces-swoosh-animation-off -bool true
    ok "workspaces-swoosh-animation-off = true"
}

apply_dock_launchpad_animation() {
    local num="$1" desc="$2"
    local before after="0 / 0"
    before="show=$(dfw read com.apple.dock springboard-show-duration 2>/dev/null || echo 'default') hide=$(dfw read com.apple.dock springboard-hide-duration 2>/dev/null || echo 'default')"
    _run_item "$num" "dock_launchpad_animation" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock springboard-show-duration -float 0
    dfw write com.apple.dock springboard-hide-duration -float 0
    ok "Launchpad animation = 0/0"
}

apply_dock_strip() {
    local num="$1" desc="$2"
    local app_names=()
    for _app in "${MACHETE_DOCK_APPS[@]}"; do
        app_names+=("$(basename "$_app" .app)")
    done
    local apps_label
    apps_label=$(IFS='+'; echo "${app_names[*]}")
    local before="(current Dock apps)" after="$apps_label only"
    _run_item "$num" "dock_strip" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.dock persistent-apps -array
    for _app in "${MACHETE_DOCK_APPS[@]}"; do
        # Encode spaces as %20 for the CFURLString
        local _url
        _url="file://$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$_app")/"
        dfw write com.apple.dock persistent-apps -array-add \
            "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${_url}</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>"
    done
    dfw write com.apple.dock show-recents -bool false
    ok "Dock stripped to: $apps_label"
}

apply_hot_corners() {
    local num="$1" desc="$2"
    local before after="all 0 (disabled)"
    before="tl=$(dfw read com.apple.dock wvous-tl-corner 2>/dev/null || echo '?') tr=$(dfw read com.apple.dock wvous-tr-corner 2>/dev/null || echo '?') bl=$(dfw read com.apple.dock wvous-bl-corner 2>/dev/null || echo '?') br=$(dfw read com.apple.dock wvous-br-corner 2>/dev/null || echo '?')"
    _run_item "$num" "hot_corners" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    for corner in tl tr bl br; do
        dfw write com.apple.dock "wvous-${corner}-corner"   -int 0
        dfw write com.apple.dock "wvous-${corner}-modifier" -int 0
    done
    ok "All hot corners disabled"
}

# ── FINDER ─────────────────────────────────────────────────────────────────

apply_finder_animations() {
    local num="$1" desc="$2"
    local before after="animations OFF"
    before=$(dfw read com.apple.finder DisableAllAnimations 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_animations" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder DisableAllAnimations -bool true
    dfw write com.apple.finder AnimateWindowZoom -bool false
    ok "Finder animations disabled"
}

apply_finder_hidden_files() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.finder AppleShowAllFiles 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_hidden_files" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder AppleShowAllFiles -bool true
    ok "AppleShowAllFiles = true"
}

apply_finder_extensions() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read NSGlobalDomain AppleShowAllExtensions 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_extensions" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain AppleShowAllExtensions -bool true
    ok "AppleShowAllExtensions = true"
}

apply_finder_path_bar() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.finder ShowPathbar 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_path_bar" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowPathbar -bool true
    ok "ShowPathbar = true"
}

apply_finder_status_bar() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.finder ShowStatusBar 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_status_bar" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowStatusBar -bool true
    ok "ShowStatusBar = true"
}

apply_finder_posix_title() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.finder _FXShowPosixPathInTitle 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_posix_title" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder _FXShowPosixPathInTitle -bool true
    ok "_FXShowPosixPathInTitle = true"
}

apply_finder_no_ext_warning() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read com.apple.finder FXEnableExtensionChangeWarning 2>/dev/null || echo "default (true)")
    _run_item "$num" "finder_no_ext_warning" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder FXEnableExtensionChangeWarning -bool false
    ok "FXEnableExtensionChangeWarning = false"
}

apply_finder_no_trash_warning() {
    local num="$1" desc="$2"
    local before after="false"
    before=$(dfw read com.apple.finder WarnOnEmptyTrash 2>/dev/null || echo "default (true)")
    _run_item "$num" "finder_no_trash_warning" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder WarnOnEmptyTrash -bool false
    ok "WarnOnEmptyTrash = false"
}

apply_finder_search_current() {
    local num="$1" desc="$2"
    local before after="SCcf (current folder)"
    before=$(dfw read com.apple.finder FXDefaultSearchScope 2>/dev/null || echo "default (SCev=everywhere)")
    _run_item "$num" "finder_search_current" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder FXDefaultSearchScope -string "SCcf"
    ok "FXDefaultSearchScope = SCcf"
}

apply_finder_folders_first() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.finder _FXSortFoldersFirst 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_folders_first" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder _FXSortFoldersFirst -bool true
    dfw write com.apple.finder _FXSortFoldersFirstOnDesktop -bool true
    ok "_FXSortFoldersFirst = true"
}

apply_finder_home_default() {
    local num="$1" desc="$2"
    local before after="PfHm (home folder)"
    before=$(dfw read com.apple.finder NewWindowTarget 2>/dev/null || echo "default (PfCm)")
    _run_item "$num" "finder_home_default" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder NewWindowTarget -string "PfHm"
    dfw write com.apple.finder NewWindowTargetPath -string "file://$REAL_HOME/"
    ok "NewWindowTarget = PfHm"
}

apply_finder_list_view() {
    local num="$1" desc="$2"
    local before after="Nlsv (list)"
    before=$(dfw read com.apple.finder FXPreferredViewStyle 2>/dev/null || echo "default (icnv)")
    _run_item "$num" "finder_list_view" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder FXPreferredViewStyle -string "Nlsv"
    # Also set list view as the default for all new windows via StandardViewSettings
    dfw write com.apple.finder "FK_DefaultViewStyle" -string "Nlsv" 2>/dev/null || true
    ok "FXPreferredViewStyle = Nlsv (list view)"
}

apply_finder_list_view_columns() {
    local num="$1" desc="$2"
    local before="(current column config)" after="name+size+dateModified+kind visible"
    _run_item "$num" "finder_list_view_columns" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    # Write ExtendedListViewSettingsV2 via pure defaults write — no python3 required
    dfw write com.apple.finder FK_StandardViewSettings -dict-add \
        ExtendedListViewSettingsV2 "$(cat << 'PLIST'
{
    calculateAllSizes = 0;
    columns = (
        { ascending = 1; identifier = name;          visible = 1; width = 300; },
        { ascending = 0; identifier = dateModified;  visible = 1; width = 181; },
        { ascending = 0; identifier = dateCreated;   visible = 0; width = 181; },
        { ascending = 0; identifier = size;          visible = 1; width = 97;  },
        { ascending = 1; identifier = kind;          visible = 1; width = 115; },
        { ascending = 1; identifier = label;         visible = 0; width = 100; },
        { ascending = 1; identifier = version;       visible = 0; width = 75;  },
        { ascending = 1; identifier = comments;      visible = 0; width = 300; },
        { ascending = 0; identifier = dateLastOpened; visible = 0; width = 200; },
        { ascending = 0; identifier = shareOwner;    visible = 0; width = 200; },
        { ascending = 0; identifier = shareLastEditor; visible = 0; width = 200; }
    );
    iconSize = 16;
    showIconPreview = 1;
    sortColumn = name;
    textSize = 13;
    useRelativeDates = 1;
    viewOptionsVersion = 1;
}
PLIST
)"
    ok "Finder list view columns configured"
}

apply_finder_list_view_icon_size() {
    local num="$1" desc="$2"
    local before after="iconSize=16 textSize=13 useRelativeDates=true"
    before=$(dfw read com.apple.finder StandardViewSettings 2>/dev/null | grep iconSize | head -1 | tr -d ' ' || echo "?")
    _run_item "$num" "finder_list_view_icon_size" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    # These are set as part of ListViewSettings inside StandardViewSettings
    dfw write com.apple.finder StandardViewSettings -dict-add ListViewSettings \
        "{ calculateAllSizes = 0; iconSize = 16; showIconPreview = 1; sortColumn = name; textSize = 13; useRelativeDates = 1; viewOptionsVersion = 1; }"
    ok "List view: 16px icons, 13pt text, relative dates"
}

apply_finder_toolbar() {
    local num="$1" desc="$2"
    local before after="TB Is Shown = 1"
    before=$(dfw read com.apple.finder "NSToolbar Configuration Browser" 2>/dev/null | grep "TB Is Shown" | tr -d ' ' || echo "default")
    _run_item "$num" "finder_toolbar" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder "NSToolbar Configuration Browser" \
        -dict-add "TB Is Shown" -int 1
    ok "Finder toolbar visible"
}

apply_finder_sidebar() {
    local num="$1" desc="$2"
    local before after="ShowSidebar=1, sidebar sections expanded"
    before=$(dfw read com.apple.finder ShowSidebar 2>/dev/null || echo "default (1)")
    _run_item "$num" "finder_sidebar" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowSidebar -bool true
    dfw write com.apple.finder FK_AppCentricShowSidebar -int 1
    # Expand all sidebar sections
    dfw write com.apple.finder SidebarDevicesSectionDisclosedState -bool true
    dfw write com.apple.finder SidebarPlacesSectionDisclosedState  -bool true
    dfw write com.apple.finder SidebarTagsSctionDisclosedState     -bool false
    ok "Finder sidebar shown, Devices+Places expanded, Tags collapsed"
}

apply_finder_preview_pane() {
    local num="$1" desc="$2"
    local before after="ShowPreviewPane=1 (right-side file details)"
    before=$(dfw read com.apple.finder ShowPreviewPane 2>/dev/null || echo "default (0)")
    _run_item "$num" "finder_preview_pane" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowPreviewPane -bool true
    ok "Finder preview pane enabled"
}

apply_finder_tab_bar() {
    local num="$1" desc="$2"
    local before after="tab bar shown"
    before=$(dfw read com.apple.finder "NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow" 2>/dev/null || echo "default (0)")
    _run_item "$num" "finder_tab_bar" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder "NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow" -bool true
    ok "Finder tab bar enabled"
}

apply_finder_terminal_service() {
    local num="$1" desc="$2"
    local before after="'New Terminal at Folder' + 'New Terminal Tab at Folder' enabled"
    # Check current state via pbs (read as real user)
    before=$(sudo -u "$REAL_USER" defaults read pbs NSServicesStatus 2>/dev/null | grep -c "com.apple.Terminal" || echo "0")
    before="${before} Terminal services registered"
    _run_item "$num" "finder_terminal_service" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    # Write to real user's pbs domain (not root's)
    sudo -u "$REAL_USER" defaults write pbs NSServicesStatus -dict-add \
        "com.apple.Terminal - New Terminal at Folder - newTerminalAtFolder" \
        '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
    sudo -u "$REAL_USER" defaults write pbs NSServicesStatus -dict-add \
        "com.apple.Terminal - New Terminal Tab at Folder - newTerminalTabAtFolder" \
        '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
    /System/Library/CoreServices/pbs -flush 2>/dev/null || killall pbs 2>/dev/null || true
    ok "Terminal services enabled — right-click folder → Services → New Terminal at Folder"
}


apply_finder_quicklook_text() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.finder QLEnableTextSelection 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_quicklook_text" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder QLEnableTextSelection -bool true
    ok "QLEnableTextSelection = true"
}

apply_finder_desktop_icons() {
    local num="$1" desc="$2"
    local before after="all desktop icons ON"
    before="hd=$(dfw read com.apple.finder ShowHardDrivesOnDesktop 2>/dev/null || echo '?')"
    _run_item "$num" "finder_desktop_icons" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowHardDrivesOnDesktop -bool true
    dfw write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
    dfw write com.apple.finder ShowRemovableMediaOnDesktop -bool true
    dfw write com.apple.finder ShowMountedServersOnDesktop -bool true
    ok "All desktop drive icons enabled"
}

apply_finder_save_panel() {
    local num="$1" desc="$2"
    local before after="true (expanded)"
    before=$(dfw read NSGlobalDomain NSNavPanelExpandedStateForSaveMode 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_save_panel" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
    dfw write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
    ok "Save panel expanded by default"
}

apply_finder_print_panel() {
    local num="$1" desc="$2"
    local before after="true (expanded)"
    before=$(dfw read NSGlobalDomain PMPrintingExpandedStateForPrint 2>/dev/null || echo "default (false)")
    _run_item "$num" "finder_print_panel" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
    dfw write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
    ok "Print panel expanded by default"
}

apply_finder_save_to_disk() {
    local num="$1" desc="$2"
    local before after="false (save to disk)"
    before=$(dfw read NSGlobalDomain NSDocumentSaveNewDocumentsToCloud 2>/dev/null || echo "default (true)")
    _run_item "$num" "finder_save_to_disk" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
    ok "NSDocumentSaveNewDocumentsToCloud = false"
}

apply_finder_no_icloud() {
    local num="$1" desc="$2"
    local before after="false (iCloud hidden)"
    before=$(dfw read com.apple.finder ShowiCloudDriveInFinder 2>/dev/null || echo "default (true)")
    _run_item "$num" "finder_no_icloud" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowiCloudDriveInFinder -bool false
    dfw write com.apple.finder ShowiCloudDesktopOnFinder -bool false
    ok "iCloud Drive hidden from Finder"
}

apply_ds_store_network() {
    local num="$1" desc="$2"
    local before after="true (no DS_Store on network vols)"
    before=$(dfw read com.apple.desktopservices DSDontWriteNetworkStores 2>/dev/null || echo "default (false)")
    _run_item "$num" "ds_store_network" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.desktopservices DSDontWriteNetworkStores -bool true
    ok "DSDontWriteNetworkStores = true"
}

apply_ds_store_usb() {
    local num="$1" desc="$2"
    local before after="true (no DS_Store on USB)"
    before=$(dfw read com.apple.desktopservices DSDontWriteUSBStores 2>/dev/null || echo "default (false)")
    _run_item "$num" "ds_store_usb" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.desktopservices DSDontWriteUSBStores -bool true
    ok "DSDontWriteUSBStores = true"
}

apply_ds_store_remove() {
    local num="$1" desc="$2"
    local before after="all .DS_Store files deleted (single-pass)"
    # Estimate count from a quick non-recursive sample for display only
    local sample
    sample=$(find "$REAL_HOME" -maxdepth 4 -name ".DS_Store" 2>/dev/null | wc -l | tr -d ' ')
    before="~${sample}+ .DS_Store files in $REAL_HOME"
    _run_item "$num" "ds_store_remove" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    # Single pass: collect into array then delete — no race between count and delete
    local deleted=0
    while IFS= read -r -d "" f; do
        rm -f "$f" 2>/dev/null && deleted=$((deleted + 1)) || true
    done < <(find "$REAL_HOME" -name ".DS_Store" -print0 2>/dev/null)
    ok "Removed $deleted .DS_Store files from $REAL_HOME"
}

# ── UI ─────────────────────────────────────────────────────────────────────

apply_green_button_maximize() {
    local num="$1" desc="$2"
    local before after="manual (maximize)"
    before=$(dfw read NSGlobalDomain AppleWindowTabbingMode 2>/dev/null || echo "default (automatic)")
    _run_item "$num" "green_button_maximize" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain AppleWindowTabbingMode -string "manual"
    ok "AppleWindowTabbingMode = manual"
}

apply_maximize_shortcut() {
    local num="$1" desc="$2"
    local before="(check NSUserKeyEquivalents)" after="Ctrl+Cmd+M = Zoom"
    _run_item "$num" "maximize_shortcut" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain NSUserKeyEquivalents -dict-add "Zoom" '@^m'
    ok "Zoom shortcut = Ctrl+Cmd+M"
}

apply_widgets_disable() {
    local num="$1" desc="$2"
    local before after="WidgetAllowList = [], widget instances = [] (all widgets removed)"
    local instance_count
    instance_count=$(dfw read com.apple.notificationcenterui widgets 2>/dev/null \
        | grep -c 'bplist' || echo "0")
    before="${instance_count} widget instance(s)"
    _run_item "$num" "widgets_disable" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    # Clear the WidgetAllowList (allowlist of permitted widget bundles)
    dfw write com.apple.notificationcenterui WidgetAllowList -array
    ok "WidgetAllowList cleared"
    # Clear all active widget instances and desktop placement storage
    dfw write com.apple.notificationcenterui widgets \
        '{ instances = (); DesktopWidgetPlacementStorage = (); vers = 1; }'
    ok "Widget instances cleared"
}

apply_screenshots() {
    local num="$1" desc="$2"
    local before="(check AppleSymbolicHotKeys)" after="keys 28/29/30/31/184 enabled"
    _run_item "$num" "screenshots" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    for spec in \
        "28|51|20|1179648" \
        "29|51|20|1441792" \
        "30|52|21|1179648" \
        "31|52|21|1441792" \
        "184|53|23|1179648"
    do
        local hk ascii kc mod
        hk=$(echo "$spec" | cut -d'|' -f1)
        ascii=$(echo "$spec" | cut -d'|' -f2)
        kc=$(echo "$spec" | cut -d'|' -f3)
        mod=$(echo "$spec" | cut -d'|' -f4)
        dfw write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$hk" \
            "{ enabled = 1; value = { parameters = ($ascii, $kc, $mod); type = standard; }; }"
    done
    ok "Screenshot shortcuts enabled (Cmd+Shift+3/4/5)"
}

apply_spotlight_shortcut() {
    local num="$1" desc="$2"
    local before="(check AppleSymbolicHotKeys key 60)" after="key 60 enabled (Cmd+Space)"
    _run_item "$num" "spotlight_shortcut" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 \
        "{ enabled = 1; value = { parameters = (32, 49, 1048576); type = standard; }; }"
    ok "Cmd+Space spotlight shortcut enabled"
}

apply_controlcenter_cleanup() {
    local num="$1" desc="$2"
    local before="(orphaned CC items)" after="Siri/AirDrop/FocusModes/ScreenMirroring/TimeMachine/Weather removed"
    _run_item "$num" "controlcenter_cleanup" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    for module in Siri AirDrop FocusModes ScreenMirroring TimeMachine Weather; do
        dfw delete com.apple.controlcenter "NSStatusItem VisibleCC $module" 2>/dev/null || true
    done
    ok "Orphaned Control Center items removed"
}

apply_wallpaper_black() {
    local num="$1" desc="$2"
    local BLACK="/System/Library/Desktop Pictures/Solid Colors/Black.png"
    local before="(current wallpaper)" after="solid black"
    _run_item "$num" "wallpaper_black" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    if [ -f "$BLACK" ]; then
        # System Events is the correct path on macOS Sonoma+ (26+).
        # The old "tell application Finder to set desktop picture" was removed.
        # System Events signals WallpaperAgent + cfprefsd correctly.
        # Inner AppleScript strings use escaped double-quotes (\") inside the
        # shell double-quote wrapper; "$ASCRIPT" preserves spaces in the path.
        local ASCRIPT
        ASCRIPT="tell application \"System Events\" to tell every desktop to set picture to \"$BLACK\""
        local _wp_err
        _wp_err=$(sudo -u "$REAL_USER" osascript -e "$ASCRIPT" 2>&1)
        if [ $? -eq 0 ]; then
            ok "Wallpaper set to solid black ($BLACK)"
        else
            warn "osascript failed: $_wp_err"
            warn "Set wallpaper manually: System Settings → Wallpaper → Solid Colors → Black"
        fi
    else
        warn "Black wallpaper image not found: $BLACK"
        warn "Available solid colors: ls \"/System/Library/Desktop Pictures/Solid Colors/\""
    fi
}

apply_timezone() {
    local num="$1" desc="$2"
    local before after="$MACHETE_TIMEZONE"
    before=$(sudo systemsetup -gettimezone 2>/dev/null | awk '{print $NF}' || echo "unknown")
    _run_item "$num" "timezone" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    local _tz_err
    _tz_err=$(sudo systemsetup -settimezone "$MACHETE_TIMEZONE" 2>&1)
    if [ $? -eq 0 ]; then
        ok "Timezone = $MACHETE_TIMEZONE"
    else
        warn "Could not set timezone: $_tz_err"
    fi
}

apply_clock_24hr() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read NSGlobalDomain AppleICUForce24HourTime 2>/dev/null || echo "default (false)")
    _run_item "$num" "clock_24hr" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain AppleICUForce24HourTime -bool true
    ok "AppleICUForce24HourTime = true"
}

apply_clock_iso_date() {
    local num="$1" desc="$2"
    local before="(current date format)" after="yyyy-MM-dd (all ICU levels)"
    _run_item "$num" "clock_iso_date" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write NSGlobalDomain AppleICUDateFormatStrings -dict \
        1 "yyyy-MM-dd" 2 "yyyy-MM-dd" 3 "yyyy-MM-dd" 4 "yyyy-MM-dd"
    dfw write NSGlobalDomain AppleICUTimeFormatStrings -dict \
        1 "HH:mm:ss" 2 "HH:mm:ss" 3 "HH:mm:ss" 4 "HH:mm:ss"
    ok "Date = yyyy-MM-dd, Time = HH:mm:ss (all ICU levels)"
}

apply_clock_seconds() {
    local num="$1" desc="$2"
    local before after="true"
    before=$(dfw read com.apple.menuextra.clock ShowSeconds 2>/dev/null || echo "default (false)")
    _run_item "$num" "clock_seconds" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.menuextra.clock ShowSeconds -bool true
    dfw write com.apple.menuextra.clock Show24Hour -bool true
    ok "Menu bar clock shows seconds"
}

apply_clock_menubar_format() {
    local num="$1" desc="$2"
    local before after="yyyy-MM-dd HH:mm:ss"
    before=$(dfw read com.apple.menuextra.clock DateFormat 2>/dev/null || echo "default")
    _run_item "$num" "clock_menubar_format" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.menuextra.clock DateFormat -string "yyyy-MM-dd HH:mm:ss"
    dfw write com.apple.menuextra.clock ShowAMPM -bool false
    dfw write com.apple.menuextra.clock ShowDate -bool false
     dfw write com.apple.menuextra.clock ShowDayOfWeek -bool false
     ok "Menu bar clock = yyyy-MM-dd HH:mm:ss"
}

apply_computer_name() {
    local num="$1" desc="$2"
    local NAME="$MACHETE_COMPUTER_NAME"
    local before after="ComputerName=$NAME  LocalHostName=$NAME  HostName=$NAME"
    before="ComputerName=$(scutil --get ComputerName 2>/dev/null || echo '?')  LocalHostName=$(scutil --get LocalHostName 2>/dev/null || echo '?')"
    _run_item "$num" "computer_name" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo scutil --set ComputerName  "$NAME"
    sudo scutil --set LocalHostName "$NAME"
    sudo scutil --set HostName      "$NAME"
    dfw write NSGlobalDomain NSUserName "$NAME" 2>/dev/null || true
    sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$NAME"
    ok "Computer name set to $NAME"
}

# ── POWER ──────────────────────────────────────────────────────────────────

apply_power_mode_auto() {
    local num="$1" desc="$2"
    local before after="1 (Auto)"
    before=$(pmset -g | awk '/powermode/{print $2}' || echo "unknown")
    _run_item "$num" "power_mode_auto" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c powermode 1
    ok "AC powermode = 1 (Auto)"
}

apply_power_display_sleep_ac() {
    local num="$1" desc="$2"
    local before after="5 min"
    before=$(pmset -g | awk '/displaysleep/{print $2}' | head -1 || echo "?")
    _run_item "$num" "power_display_sleep_ac" "$desc" "$before min" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c displaysleep 5
    ok "AC displaysleep = 5"
}

apply_power_system_sleep_ac() {
    local num="$1" desc="$2"
    local before after="10 min"
    before=$(pmset -g | awk '/^[ ]+sleep /{print $2}' | head -1 || echo "?")
    _run_item "$num" "power_system_sleep_ac" "$desc" "$before min" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c sleep 10
    ok "AC sleep = 10"
}

apply_power_clamshell() {
    local num="$1" desc="$2"
    local before after="acwake=1 lidwake=1 ttyskeepawake=1"
    before="acwake=$(pmset -g | awk '/acwake/{print $2}' || echo '?')"
    _run_item "$num" "power_clamshell" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c acwake 1
    sudo pmset -c lidwake 1
    sudo pmset -c ttyskeepawake 1
    ok "Clamshell mode enabled (AC)"
}

apply_power_nap_ac() {
    local num="$1" desc="$2"
    local before after="0 (off)"
    before=$(pmset -g | awk '/powernap/{print $2}' | head -1 || echo "?")
    _run_item "$num" "power_nap_ac" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c powernap 0
    ok "AC powernap = 0"
}

apply_power_disk_sleep_ac() {
    local num="$1" desc="$2"
    local before after="10 min"
    before=$(pmset -g | awk '/disksleep/{print $2}' | head -1 || echo "?")
    _run_item "$num" "power_disk_sleep_ac" "$desc" "$before min" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c disksleep 10
    ok "AC disksleep = 10"
}

apply_power_display_sleep_bat() {
    local num="$1" desc="$2"
    local before after="2 min"
    before=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/displaysleep/{print $2; exit}' || echo "?")
    _run_item "$num" "power_display_sleep_bat" "$desc" "$before min" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b displaysleep 2
    ok "Battery displaysleep = 2"
}

apply_power_system_sleep_bat() {
    local num="$1" desc="$2"
    local before after="5 min"
    before=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/^[ ]+sleep /{print $2; exit}' || echo "?")
    _run_item "$num" "power_system_sleep_bat" "$desc" "$before min" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b sleep 5
    ok "Battery sleep = 5"
}

apply_power_standby_bat() {
    local num="$1" desc="$2"
    local before after="0 (off — no background wake cycle)"
    before=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/standby/{print $2; exit}' || echo "?")
    _run_item "$num" "power_standby_bat" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b standby 0
    ok "Battery standby = 0"
}

apply_power_nap_bat() {
    local num="$1" desc="$2"
    local before after="0 (off)"
    before=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/powernap/{print $2; exit}' || echo "?")
    _run_item "$num" "power_nap_bat" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b powernap 0
    ok "Battery powernap = 0"
}

# ── NETWORK ────────────────────────────────────────────────────────────────

apply_tcp_socket_buffer() {
    local num="$1" desc="$2"
    local before after="16777216 (16 MB)"
    before=$(sysctl -n kern.ipc.maxsockbuf 2>/dev/null || echo "?")
    _run_item "$num" "tcp_socket_buffer" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo sysctl -w kern.ipc.maxsockbuf=16777216
    ok "kern.ipc.maxsockbuf = 16777216"
}

apply_tcp_send_recv_space() {
    local num="$1" desc="$2"
    local before after="1048576 (1 MB each)"
    before="send=$(sysctl -n net.inet.tcp.sendspace 2>/dev/null || echo '?') recv=$(sysctl -n net.inet.tcp.recvspace 2>/dev/null || echo '?')"
    _run_item "$num" "tcp_send_recv_space" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo sysctl -w net.inet.tcp.sendspace=1048576
    sudo sysctl -w net.inet.tcp.recvspace=1048576
    ok "TCP send/recv space = 1048576"
}

apply_tcp_somaxconn() {
    local num="$1" desc="$2"
    local before after="2048"
    before=$(sysctl -n kern.ipc.somaxconn 2>/dev/null || echo "?")
    _run_item "$num" "tcp_somaxconn" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo sysctl -w kern.ipc.somaxconn=2048
    ok "kern.ipc.somaxconn = 2048"
}

apply_sysctl_perf() {
    local num="$1" desc="$2"
    # Only kern.maxvnodes is safe to raise on Apple Silicon macOS 26.4.
    # kern.maxproc/maxfiles/maxfilesperproc are already set higher by the OS
    # (16000/491520/245760) — the GitHub-sourced values (2048/200000/100000)
    # would have LOWERED them, which is wrong. kern.ipc.nmbclusters is read-only.
    local before after="kern.maxvnodes=750000"
    before="maxvnodes=$(sysctl -n kern.maxvnodes 2>/dev/null || echo '?')"
    _run_item "$num" "sysctl_perf" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo sysctl -w kern.maxvnodes=750000
    ok "kern.maxvnodes = 750000"
}

apply_sysctl_persist() {
    local num="$1" desc="$2"
    local before after="/etc/sysctl.conf written"
    [ -f /etc/sysctl.conf ] && before="exists ($(wc -l < /etc/sysctl.conf | tr -d ' ') lines)" || before="does not exist"
    _run_item "$num" "sysctl_persist" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo tee /etc/sysctl.conf > /dev/null << 'SCTLEOF'
# sysctl.conf — managed by optimizations.sh
# Rollback: delete this file and reboot
# Note: kern.maxproc/maxfiles/maxfilesperproc intentionally omitted —
#       macOS 26.4 ships with higher values already (16000/491520/245760).
#       kern.ipc.nmbclusters is read-only on this platform.
#       net.inet.tcp.delayed_ack removed — net loss on Wi-Fi-only machine.

kern.ipc.maxsockbuf=16777216
net.inet.tcp.sendspace=1048576
net.inet.tcp.recvspace=1048576
kern.ipc.somaxconn=2048
net.inet.tcp.mssdflt=1440
net.inet.tcp.blackhole=2
kern.maxvnodes=750000
SCTLEOF
    ok "/etc/sysctl.conf written"
}

apply_chrome_doh() {
    local num="$1" desc="$2"
    local POLICY_USER="${SUDO_USER:-$(id -un)}"
    local PLIST="/Library/Managed Preferences/$POLICY_USER/com.google.Chrome.plist"
    local before after="DnsOverHttpsMode=off"
    [ -f "$PLIST" ] && before=$(sudo /usr/libexec/PlistBuddy -c "Print :DnsOverHttpsMode" "$PLIST" 2>/dev/null || echo "not set") || before="policy not present"
    _run_item "$num" "chrome_doh" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo mkdir -p "/Library/Managed Preferences/$POLICY_USER"
    sudo /usr/libexec/PlistBuddy \
        -c "Add :DnsOverHttpsMode string off" "$PLIST" 2>/dev/null || \
    sudo /usr/libexec/PlistBuddy \
        -c "Set :DnsOverHttpsMode off" "$PLIST"
    ok "Chrome DoH = off (managed policy)"
}

apply_dns_flush() {
    local num="$1" desc="$2"
    local before="(current DNS cache)" after="flushed"
    _run_item "$num" "dns_flush" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    ok "DNS cache flushed"
}

# ── UPDATES ────────────────────────────────────────────────────────────────

apply_apple_autoupdate() {
    local num="$1" desc="$2"
    local before after="AutomaticCheckEnabled=false (user + system domain)"
    before=$(dfw read com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null || echo "default (true)")
    _run_item "$num" "apple_autoupdate" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.commerce AutoUpdate -bool false
    dfw write com.apple.SoftwareUpdate AutomaticDownload -bool false
    dfw write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
    ok "Apple Software Update disabled (user + system domain)"
}

apply_chrome_keystone() {
    local num="$1" desc="$2"
    local before after="all 4 Keystone plists disabled"
    before="(checking)"
    _run_item "$num" "chrome_keystone" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    for plist_label in \
        "gui/$REAL_UID/com.google.keystone.agent:/Library/LaunchAgents/com.google.keystone.agent.plist" \
        "gui/$REAL_UID/com.google.keystone.xpcservice:/Library/LaunchAgents/com.google.keystone.xpcservice.plist" \
        "system/com.google.keystone.daemon:/Library/LaunchDaemons/com.google.keystone.daemon.plist" \
        "system/com.google.GoogleUpdater.wake.system:/Library/LaunchDaemons/com.google.GoogleUpdater.wake.system.plist"
    do
        local domain_label="${plist_label%%:*}"
        local plist_path="${plist_label##*:}"
        if [ -f "$plist_path" ]; then
            launchctl disable "$domain_label" 2>/dev/null || true
            launchctl bootout "$domain_label" 2>/dev/null || true
            log "  Disabled: $domain_label"
        fi
    done
    dfw write com.google.Keystone ShouldCheckForUpdates -bool false 2>/dev/null || true
    sudo killall GoogleUpdater 2>/dev/null || true
    ok "Chrome Keystone disabled"
}

apply_edge_updater() {
    local num="$1" desc="$2"
    local before after="com.microsoft.EdgeUpdater.wake disabled"
    local PLIST="$REAL_HOME/Library/LaunchAgents/com.microsoft.EdgeUpdater.wake.plist"
    [ -f "$PLIST" ] && before="present" || before="not installed"
    _run_item "$num" "edge_updater" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    if [ -f "$PLIST" ]; then
        launchctl disable "gui/$REAL_UID/com.microsoft.EdgeUpdater.wake" 2>/dev/null || true
        launchctl bootout "gui/$REAL_UID/com.microsoft.EdgeUpdater.wake" 2>/dev/null || true
    fi
    sudo killall EdgeUpdater 2>/dev/null || true
    ok "Edge updater disabled"
}

apply_airdrop() {
    local num="$1" desc="$2"
    local before after="true (disabled)"
    before=$(dfw read com.apple.NetworkBrowser DisableAirDrop 2>/dev/null || echo "default (false)")
    _run_item "$num" "airdrop" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.NetworkBrowser DisableAirDrop -bool true
    ok "AirDrop disabled"
}

apply_handoff_continuity() {
    local num="$1" desc="$2"
    local before after="ActivityReceiving/AdvertisingAllowed = false"
    before=$(dfw -currentHost read com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null || echo "default (true)")
    _run_item "$num" "handoff_continuity" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    dfw -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool false
    dfw -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool false
    ok "Handoff and Continuity disabled"
}

apply_chrome_crashpad() {
    local num="$1" desc="$2"
    local CPDIR="$REAL_HOME/Library/Application Support/Google/RLZ/Crashpad"
    local before after="settings.dat created"
    [ -f "$CPDIR/settings.dat" ] && before="already exists" || before="missing (causes log error)"
    _run_item "$num" "chrome_crashpad" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo -u "$REAL_USER" mkdir -p "$CPDIR"
    sudo -u "$REAL_USER" touch "$CPDIR/settings.dat"
    ok "Chrome Crashpad settings.dat created"
}

# ── SECURITY ───────────────────────────────────────────────────────────────
apply_smb_guest() {
    local num="$1" desc="$2"
    local SMB_PLIST="/Library/Preferences/SystemConfiguration/com.apple.smb.server"
    local before after="false (auth required)"
    before=$(defaults read "$SMB_PLIST" AllowGuestAccess 2>/dev/null || echo "default (enabled)")
    _run_item "$num" "smb_guest" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo defaults write "$SMB_PLIST" AllowGuestAccess -bool false
    ok "SMB AllowGuestAccess = false"
}

apply_ssh_server() {
    local num="$1" desc="$2"
    local before after="off"
    before=$(sudo systemsetup -getremotelogin 2>/dev/null | awk '{print $NF}' || echo "?")
    _run_item "$num" "ssh_server" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    local _ssh_err
    _ssh_err=$(echo "yes" | sudo systemsetup -setremotelogin off 2>&1)
    if [ $? -eq 0 ]; then
        ok "SSH server disabled"
    else
        warn "Could not disable SSH server: $_ssh_err"
    fi
}

apply_remote_apple_events() {
    local num="$1" desc="$2"
    local before after="off"
    before=$(sudo systemsetup -getremoteappleevents 2>/dev/null | awk '{print $NF}' || echo "?")
    _run_item "$num" "remote_apple_events" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    # Already off — systemsetup -set* requires Full Disk Access but -get* does not.
    # Skip the setter if the value is already correct to avoid a spurious warning.
    if [ "$before" = "Off" ]; then
        ok "Remote Apple Events already off — skipping setter"
        return 0
    fi
    local _rae_err
    _rae_err=$(sudo systemsetup -setremoteappleevents off 2>&1)
    if [ $? -eq 0 ]; then
        ok "Remote Apple Events disabled"
    else
        warn "Could not disable Remote Apple Events: $_rae_err"
    fi
}

apply_gatekeeper() {
    local num="$1" desc="$2"
    local before after="disabled (allow unsigned binaries)"
    before=$(spctl --status 2>/dev/null | head -1 || echo "?")
    _run_item "$num" "gatekeeper" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    local _gk_err
    _gk_err=$(sudo spctl --master-disable 2>&1)
    if [ $? -eq 0 ]; then
        ok "Gatekeeper disabled  (rollback: sudo spctl --master-enable)"
    else
        warn "Could not disable Gatekeeper: $_gk_err"
    fi
}

apply_mdns_multicast() {
    local num="$1" desc="$2"
    local MDNS_PLIST="/Library/Preferences/com.apple.mDNSResponder.plist"
    local before after="NoMulticastAdvertisements=true"
    before=$(sudo defaults read "$MDNS_PLIST" NoMulticastAdvertisements 2>/dev/null || echo "default (false)")
    _run_item "$num" "mdns_multicast" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    sudo defaults write "$MDNS_PLIST" NoMulticastAdvertisements -bool true
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    ok "mDNS multicast advertisements suppressed"
}

apply_hosts_telemetry() {
    local num="$1" desc="$2"
    local TELEMETRY_HOSTS=(
        "metrics.icloud.com" "xp.apple.com" "api.smoot.apple.com"
        "pancake.apple.com" "iphone-wu.apple.com" "bag.itunes.apple.com"
        "p33-keyvalueservice.icloud.com" "configuration.apple.com"
        "appleid.cdn-apple.com" "feedbackws.icloud.com" "diagassets.apple.com"
    )
    local already=0
    for h in "${TELEMETRY_HOSTS[@]}"; do
        grep -qF "$h" /etc/hosts 2>/dev/null && already=$((already+1))
    done
    local before="$already/${#TELEMETRY_HOSTS[@]} already blocked" after="all 11 blocked in /etc/hosts"
    _run_item "$num" "hosts_telemetry" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    local added=0
    for h in "${TELEMETRY_HOSTS[@]}"; do
        if ! grep -qF "$h" /etc/hosts 2>/dev/null; then
            echo "0.0.0.0 $h" | sudo tee -a /etc/hosts > /dev/null
            added=$((added+1))
        fi
    done
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    ok "Added $added telemetry entries to /etc/hosts"
}

apply_pfctl_telemetry() {
    local num="$1" desc="$2"
    local ANCHOR="/etc/pf.anchors/telemetry-block"
    local DAEMON_PLIST="/Library/LaunchDaemons/local.telemetry-pf.plist"
    local before after="standalone LaunchDaemon loads anchor at every boot"
    [ -f "$DAEMON_PLIST" ] && before="LaunchDaemon present" || before="not installed"
    _run_item "$num" "pfctl_telemetry" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0

    # Step 1: Write anchor rules file
    sudo tee "$ANCHOR" > /dev/null << 'PFEOF'
# Block outbound telemetry — managed by optimizations.sh
# Rollback: launchctl bootout system/local.telemetry-pf
#           rm /Library/LaunchDaemons/local.telemetry-pf.plist
#           rm /etc/pf.anchors/telemetry-block
block out quick proto { tcp udp } to metrics.icloud.com
block out quick proto { tcp udp } to feedbackws.icloud.com
block out quick proto { tcp udp } to xp.apple.com
block out quick proto { tcp udp } to diagassets.apple.com
block out quick proto { tcp udp } to api.smoot.apple.com
block out quick proto { tcp udp } to pancake.apple.com
PFEOF

    # Step 2: Write LaunchDaemon plist — owns the lifecycle, survives OS updates
    # /etc/pf.conf is NOT modified. This daemon loads our anchor independently.
    sudo tee "$DAEMON_PLIST" > /dev/null << 'DAEMONEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.telemetry-pf</string>
    <key>ProgramArguments</key>
    <array>
        <string>/sbin/pfctl</string>
        <string>-e</string>
        <string>-f</string>
        <string>/etc/pf.anchors/telemetry-block</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/telemetry-pf.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/telemetry-pf.log</string>
</dict>
</plist>
DAEMONEOF

    # Step 3: Load it now (bootout first in case it was already loaded)
    sudo launchctl bootout system/local.telemetry-pf 2>/dev/null || true
    sudo launchctl bootstrap system "$DAEMON_PLIST"
    ok "pfctl telemetry block active via LaunchDaemon (survives OS updates)"
    ok "Rollback: sudo launchctl bootout system/local.telemetry-pf && sudo rm $DAEMON_PLIST $ANCHOR"
}

apply_alf_firewall() {
    local num="$1" desc="$2"
    local FW="/usr/libexec/ApplicationFirewall/socketfilterfw"
    local before after="enabled + stealth mode on"
    before=$("$FW" --getglobalstate 2>/dev/null | head -1 || echo "?")
    _run_item "$num" "alf_firewall" "$desc" "$before" "$after" || return 0
    [ "$DRY_RUN" = true ] && return 0
    local _fw_ok=true _fw_err
    _fw_err=$(sudo "$FW" --setglobalstate on 2>&1)  || { warn "Firewall setglobalstate on: $_fw_err"; _fw_ok=false; }
    _fw_err=$(sudo "$FW" --setstealthmode on 2>&1)   || { warn "Firewall setstealthmode on: $_fw_err"; _fw_ok=false; }
    _fw_err=$(sudo "$FW" --setallowsigned on 2>&1)   || { warn "Firewall setallowsigned on: $_fw_err"; _fw_ok=false; }
    _fw_err=$(sudo "$FW" --setblockall off 2>&1)      || { warn "Firewall setblockall off: $_fw_err"; _fw_ok=false; }
    if [ "$_fw_ok" = true ]; then
        ok "ALF firewall enabled with stealth mode"
    else
        warn "ALF firewall partially configured — check warnings above"
    fi
}


# ---------------------------------------------------------------------------
# --backup: snapshot all current preference values → restore script
# ---------------------------------------------------------------------------
run_backup() {
    local RESTORE_SCRIPT="$SCRIPT_DIR/restore-$(date +%Y%m%d-%H%M%S).sh"
    header "BACKUP MODE — snapshotting current values"
    log "Writing restore script: $RESTORE_SCRIPT"
    echo "#!/bin/bash" > "$RESTORE_SCRIPT"
    echo "# Restore script generated by optimizations.sh --backup" >> "$RESTORE_SCRIPT"
    echo "# Run: sudo ./$(basename "$RESTORE_SCRIPT") to revert all settings" >> "$RESTORE_SCRIPT"
    echo "REAL_USER=\"${REAL_USER}\"" >> "$RESTORE_SCRIPT"
    echo "dfw() { sudo -u \"\$REAL_USER\" defaults \"\$@\"; }" >> "$RESTORE_SCRIPT"
    echo "" >> "$RESTORE_SCRIPT"

    # Snapshot every defaults key touched by this script
    local keys=(
        "NSGlobalDomain KeyRepeat"
        "NSGlobalDomain InitialKeyRepeat"
        "NSGlobalDomain ApplePressAndHoldEnabled"
        "NSGlobalDomain com.apple.trackpad.scaling"
        "NSGlobalDomain com.apple.mouse.scaling"
        "NSGlobalDomain com.apple.springing.delay"
        "NSGlobalDomain NSAutomaticWindowAnimationsEnabled"
        "NSGlobalDomain NSWindowResizeTime"
        "NSGlobalDomain NSScrollAnimationEnabled"
        "NSGlobalDomain NSScrollViewRubberbanding"
        "NSGlobalDomain AppleReduceDesktopTinting"
        "NSGlobalDomain SLSMenuBarUseBlurredAppearance"
        "NSGlobalDomain AppleShowAllExtensions"
        "NSGlobalDomain AppleWindowTabbingMode"
        "NSGlobalDomain NSDocumentSaveNewDocumentsToCloud"
        "NSGlobalDomain AppleICUForce24HourTime"
        "NSGlobalDomain NSNavPanelExpandedStateForSaveMode"
        "NSGlobalDomain PMPrintingExpandedStateForPrint"
        "com.apple.universalaccess reduceMotion"
        "com.apple.dock autohide"
        "com.apple.dock autohide-delay"
        "com.apple.dock autohide-time-modifier"
        "com.apple.dock launchanim"
        "com.apple.dock no-bouncing"
        "com.apple.dock expose-animation-duration"
        "com.apple.dock minimize-to-application"
        "com.apple.dock mineffect"
        "com.apple.dock show-recents"
        "com.apple.finder DisableAllAnimations"
        "com.apple.finder AppleShowAllFiles"
        "com.apple.finder ShowPathbar"
        "com.apple.finder ShowStatusBar"
        "com.apple.finder _FXShowPosixPathInTitle"
        "com.apple.finder FXEnableExtensionChangeWarning"
        "com.apple.finder WarnOnEmptyTrash"
        "com.apple.finder FXDefaultSearchScope"
        "com.apple.finder _FXSortFoldersFirst"
        "com.apple.finder FXPreferredViewStyle"
        "com.apple.finder ShowSidebar"
        "com.apple.finder ShowPreviewPane"
        "com.apple.finder NewWindowTarget"
        "com.apple.finder ShowiCloudDriveInFinder"
        "com.apple.desktopservices DSDontWriteNetworkStores"
        "com.apple.desktopservices DSDontWriteUSBStores"
        "com.apple.notificationcenterui WidgetAllowList"
        "com.apple.menuextra.clock DateFormat"
        "com.apple.menuextra.clock ShowSeconds"
        "com.apple.NetworkBrowser DisableAirDrop"
        "com.apple.Spotlight orderedItems"
        "com.apple.Spotlight SiriSuggestionsEnabled"
        "com.apple.SoftwareUpdate AutomaticCheckEnabled"
        "com.apple.AppleMultitouchTrackpad Clicking"
        "com.apple.AppleMultitouchTrackpad Dragging"
    )

    local saved=0
    for key_pair in "${keys[@]}"; do
        local domain="${key_pair%% *}"
        local key="${key_pair#* }"
        local val
        val=$(sudo -u "$REAL_USER" defaults read "$domain" "$key" 2>/dev/null) || continue
        # Detect type
        local type_flag="-string"
        case "$val" in
            0|1)                   type_flag="-bool" ;;
            [0-9]*)                type_flag="-int" ;;
            *"."[0-9]*)            type_flag="-float" ;;
        esac
        printf 'dfw write %s %s %s "%s"
' "$domain" "$key" "$type_flag" "$val" >> "$RESTORE_SCRIPT"
        saved=$((saved + 1))
    done

    # Snapshot pmset
    echo "" >> "$RESTORE_SCRIPT"
    echo "# Power settings" >> "$RESTORE_SCRIPT"
    pmset -g custom 2>/dev/null | while IFS= read -r line; do
        echo "# $line" >> "$RESTORE_SCRIPT"
    done

    # Snapshot sysctl
    echo "" >> "$RESTORE_SCRIPT"
     echo "# sysctl (current values — apply manually if needed)" >> "$RESTORE_SCRIPT"
     for k in kern.ipc.maxsockbuf net.inet.tcp.sendspace \
               net.inet.tcp.recvspace kern.ipc.somaxconn kern.maxvnodes; do
        local v
        v=$(sysctl -n "$k" 2>/dev/null) || continue
        echo "# sudo sysctl -w $k=$v" >> "$RESTORE_SCRIPT"
    done

    chmod +x "$RESTORE_SCRIPT"
    ok "Backed up $saved preference keys"
    ok "Restore script: $RESTORE_SCRIPT"
    ok "Run to revert: sudo $RESTORE_SCRIPT"
}


# ---------------------------------------------------------------------------
# DISPATCH TABLE — key → function name
# ---------------------------------------------------------------------------
dispatch_apply() {
    local num="$1" key="$2" desc="$3"
    local fn="apply_${key}"
    if declare -f "$fn" > /dev/null 2>&1; then
        "$fn" "$num" "$desc"
    else
        warn "No apply function for key: $key"
    fi
}

# ---------------------------------------------------------------------------
# POST-RUN: flush prefs + restart affected UI processes
# ---------------------------------------------------------------------------
_flush_prefs() {
    if [ "$DRY_RUN" = true ]; then return 0; fi
    log "Flushing preference writes (cfprefsd)..."
    sudo -u "$REAL_USER" killall cfprefsd 2>/dev/null || killall cfprefsd 2>/dev/null || true
    sleep 1
    log "Restarting Dock and ControlCenter..."
    launchctl kickstart -k "gui/$REAL_UID/com.apple.Dock.agent"   2>/dev/null || true
    launchctl kickstart -k "gui/$REAL_UID/com.apple.controlcenter" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# MAIN — iterate work list
# ---------------------------------------------------------------------------

# --backup: run before checking work list (backup doesn't need items)
if [ "$BACKUP_MODE" = true ]; then
    run_backup
    exit 0
fi

if [ ${#WORK_LIST[@]} -eq 0 ]; then
    warn "No items match the given filters. Use --list to see all keys."
    exit 0
fi

APPLIED=0
SKIPPED=0
NUM=0

for entry in "${WORK_LIST[@]}"; do
    NUM=$((NUM + 1))
    orig_idx=$(echo "$entry" | cut -d'|' -f1)
    key=$(echo "$entry"      | cut -d'|' -f2)
    group=$(echo "$entry"    | cut -d'|' -f3)
    desc=$(echo "$entry"     | cut -d'|' -f4)

    if [ "$DRY_RUN" = false ] && [ "$NUM" = 1 ]; then
        header "Processing ${#WORK_LIST[@]} optimization(s)"
    fi

    dispatch_apply "$NUM" "$key" "$desc"
    result=$?
    if [ "$result" = 0 ] && [ "$DRY_RUN" = false ]; then
        APPLIED=$((APPLIED + 1))
    else
        SKIPPED=$((SKIPPED + 1))
    fi
done

# ---------------------------------------------------------------------------
# Flush + restart UI (skip on dry-run)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = false ] && [ "$APPLIED" -gt 0 ]; then
    echo ""
    _flush_prefs
    if [ "$SPOTLIGHT_CHANGED" = true ]; then
        log "Spotlight settings changed — rebuilding index (this takes a few minutes)..."
        sudo mdutil -E / 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "SUMMARY"
log "Items processed: ${#WORK_LIST[@]}"
if [ "$DRY_RUN" = true ]; then
    log "DRY RUN — no changes made"
else
    log "Applied: $APPLIED  |  Skipped: $SKIPPED"
    if [ "$APPLIED" -gt 0 ]; then
        echo ""
        echo "  Some changes require logout/login to fully take effect."
        echo "  Power settings take effect immediately."
        echo "  sysctl settings persist via /etc/sysctl.conf across reboots."
    fi
fi
log "Log: $LOG"
echo ""
