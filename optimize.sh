#!/bin/bash
# ==============================================================================
# OPTIMIZATIONS — macOS 26.4 / Apple M5 Max
# 116 individually confirmed system preferences and tuning settings.
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
#   network      TCP tuning, sysctl, DNS flush
#   updates      Apple SU, AirDrop, Handoff
#   security     SMB guest, SSH, Remote Events, Gatekeeper, TCC, mDNS, ALF
#
# DEPENDENCIES:
#   - PlistBuddy (/usr/libexec/PlistBuddy) — used by Chrome managed policy functions
#     Note: Bundled with macOS base system. If missing, chrome_* items will fail gracefully.
#   - No Xcode Command Line Tools required (python3 dependency removed)
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
# URL encoding (pure bash, no python3/CLT dependency)
# ---------------------------------------------------------------------------
url_encode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9/] ) o="$c" ;;
            ' ' ) o='%20' ;;
            * ) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded+="$o"
    done
    echo "$encoded"
}

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
    "key_repeat_rate|input|Key repeat rate → 1 (fastest: ~15ms between repeated keystrokes, default is 90ms — eliminates lag when holding arrow keys or deleting text)"
    "key_repeat_delay|input|Initial key repeat delay → 10 (~150ms before repeat starts, default 375ms — key held for a quarter second before it starts repeating)"
    "press_and_hold|input|Disable press-and-hold accent picker — restores key repeat in every app (Xcode, VS Code, Terminal) instead of showing the accent popup on long press"
    "touchid_sudo|input|Enable Touch ID for sudo — authenticate terminal sudo prompts with fingerprint instead of typing password (writes pam_tid.so to /etc/pam.d/sudo_local)"
    "text_substitution|input|Disable smart quotes, smart dashes, auto-capitalisation, and double-space-to-period — all four silently corrupt code pasted into Terminal or any native text field; smart quotes replace straight quotes with curly ones causing immediate shell syntax errors"
    "sudo_timeout|input|Raise sudo credential timeout to 30 min (default 5 min) — writes a Defaults entry to /etc/sudoers.d/sudo_timeout; stops sudo re-prompting every 5 minutes during long build/deploy sessions without permanently disabling the password requirement"
    # ── trackpad ────────────────────────────────────────────────────────────
    "trackpad_speed|trackpad|Trackpad tracking speed → 3.0 (maximum, default 1.5) — cursor travels further per mm of finger movement, less wrist travel on large displays"
    "mouse_speed|trackpad|Mouse tracking speed → 3.0 (maximum, default 1.5) — same physical-to-screen ratio improvement as trackpad_speed but for external mice"
    "spring_load|trackpad|Spring-loading delay → 0.1s (default 0.5s) — folders pop open almost instantly when you hover over them while dragging a file, reducing drag-and-drop steps"
    "tap_to_click|trackpad|Enable tap-to-click — a light tap registers as a click without physically pressing the trackpad down, reducing fatigue and noise"
    "tap_to_drag|trackpad|Enable tap-to-drag — double-tap and hold to drag without a physical press; complements tap-to-click for moving windows and files"
    "three_finger_drag|trackpad|Enable 3-finger drag — drag windows, select text, and move files by swiping with three fingers; more ergonomic than click-and-hold for extended drags"
    "three_finger_tap|trackpad|Disable 3-finger tap Look Up — prevents accidental dictionary popups when gesturing; look up still works via Force Touch"
    "natural_scroll|trackpad|Natural scroll OFF — restores traditional direction (wheel down = page down) matching every non-Apple scroll device and most muscle memory"
    # ── spotlight ───────────────────────────────────────────────────────────
    "spotlight_boot_volume|spotlight|Keep Spotlight indexing ON for the boot volume — required for Cmd+Space app search; without it Spotlight cannot find any installed apps"
    "spotlight_external_volumes|spotlight|Disable Spotlight indexing on external and non-boot volumes — stops mds/mdworker from spinning up and consuming CPU whenever a drive is mounted"
    "spotlight_exclusions|spotlight|Clear overly broad Spotlight ExclusionPaths — removes exclusions that can prevent legitimate app search results from appearing"
    "spotlight_categories|spotlight|Restrict Spotlight to Apps, Calculator, and System Settings only — eliminates web search suggestions, contacts, mail, and documents from results, reducing index queries and RAM usage"
    "spotlight_siri|spotlight|Disable Siri suggestions in Spotlight — stops Spotlight from sending each keypress to Apple servers for suggestion lookup, faster local-only results"
    "spotlight_pref_rules|spotlight|Remove stale Spotlight preference rules left by uninstalled apps — prevents mdworker from waking to evaluate rules for apps that no longer exist"
    # ── animations ──────────────────────────────────────────────────────────
    "window_animations|animations|Disable window open/close animations — windows appear and disappear instantly; eliminates the zoom-in/zoom-out compositing work on every app launch and quit"
    "window_resize_time|animations|Window resize duration → 0.001s (effectively instant, default 0.2s) — drag-to-resize and programmatic resize feel immediate with no rubber-band lag"
    "scroll_animation|animations|Disable smooth scroll momentum — scroll position snaps immediately to where you stop scrolling; eliminates the coasting animation that delays reaching your target"
    "rubber_band|animations|Disable rubber-band overscroll bounce — content stays at the edge instead of springing back; stops accidental over-scrolling triggering unnecessary redraws"
    "reduce_motion|animations|Enable Reduce Motion — replaces parallax, space-switch swoosh fly, and zoom transitions with simple cross-fades; measurably reduces GPU load during workspace switching"
    "desktop_tinting|animations|Disable wallpaper tinting of UI chrome — stops the OS sampling the wallpaper colour and blending it into window titlebars and menus; eliminates the per-frame recomposite that occurs when windows move over the desktop"
    "menubar_blur|animations|Disable menu bar blur compositing — removes the real-time frosted-glass blur behind the menu bar, saving ~15-20% WindowServer GPU time on Apple Silicon"
    # ── dock ────────────────────────────────────────────────────────────────
    "dock_autohide|dock|Auto-hide the Dock — reclaims the full screen height at all times; Dock slides in only when the cursor reaches the screen edge"
    "dock_autohide_delay|dock|Dock appear delay → 0 (default 0.5s) — Dock begins sliding in the instant the cursor hits the screen edge instead of waiting half a second"
    "dock_autohide_animation|dock|Dock slide animation → 0.15s (default 0.5s) — Dock snaps in quickly without the full half-second slide; set to 0 for completely instant if preferred"
    "dock_launch_animation|dock|Disable app launch bounce — the Dock icon stops bouncing when an app is opening; eliminates the animation work and distraction during every launch"
    "dock_no_bounce|dock|Disable notification bounce — app icons stop bouncing in the Dock when they want attention; reduces distraction and unnecessary animation CPU usage"
    "dock_expose_animation|dock|Mission Control animation → instant (default ~0.3s) — all windows spread out immediately on Ctrl+Up without the fly-apart animation delay"
    "dock_minimize_to_app|dock|Minimize into app icon — minimized windows merge into the app's Dock icon instead of creating a separate thumbnail slot, keeping the Dock uncluttered"
    "dock_minimize_effect|dock|Minimize effect → scale (default genie) — the scale effect is computationally cheaper than the genie warp; noticeable when minimizing large windows"
    "dock_space_animation|dock|Disable Space-switch swoosh animation — switching desktops snaps immediately instead of the full horizontal slide across the screen"
    "dock_launchpad_animation|dock|Disable Launchpad open/close animation — Launchpad appears and dismisses instantly without the scale-in/scale-out zoom"
    "dock_strip|dock|Strip Dock to essential apps only (configured in MACHETE_DOCK_APPS) and hide Recent Apps — removes clutter and prevents the Dock from resizing dynamically as recents change"
    "hot_corners|dock|Disable all hot corners — prevents accidental Screen Saver, Mission Control, or Desktop triggers when moving the cursor quickly to a screen corner"
    # ── finder ──────────────────────────────────────────────────────────────
    "finder_animations|finder|Disable all Finder animations (window zoom, folder open transitions) — Finder responds instantly to navigation without waiting for slide-in effects"
    "finder_hidden_files|finder|Show hidden files and dotfiles — .zshrc, .ssh, .config and other dotfiles are visible in every Finder window without needing to toggle them each session"
    "finder_extensions|finder|Always show file extensions — .app, .sh, .py, .json are always visible; prevents accidental double-extension on rename and makes file types unambiguous"
    "finder_path_bar|finder|Show path bar at bottom of Finder window — displays the full folder hierarchy from / to the current location; click any segment to navigate up instantly"
    "finder_status_bar|finder|Show status bar at bottom of Finder window — shows item count and available disk space for the current location without opening Get Info"
    "finder_posix_title|finder|Show full POSIX path in Finder title bar — the window title shows /Users/you/Documents/project instead of just 'project'; useful for confirming location"
    "finder_no_ext_warning|finder|Suppress extension-change warning — renaming file.txt to file.md no longer prompts a confirmation dialog on every rename"
    "finder_no_trash_warning|finder|Suppress empty-Trash confirmation — removes the 'Are you sure?' dialog when emptying; undo (Cmd+Z) remains available immediately after"
    "finder_search_current|finder|Search current folder by default — Cmd+F searches the open folder instead of the entire Mac; prevents slow system-wide searches when you just need a local result"
    "finder_folders_first|finder|Sort folders before files in list view and on the desktop — directories always appear at the top of any sorted column, matching the convention of most other OSes and terminals"
    "finder_home_default|finder|New Finder windows open to home folder — every new window starts at ~ instead of Recents or iCloud Drive"
    "finder_list_view|finder|Default Finder view → list view — list view shows the most information per pixel and sorts consistently; replaces icon view (wastes space) and column view (inconsistent widths)"
    "finder_list_view_columns|finder|Configure list view columns — shows Name, Date Modified, Size, and Kind; hides less-useful columns (Date Created, Label, Comments) to reduce horizontal scroll"
    "finder_list_view_icon_size|finder|List view icon size 16px, text 13pt, relative dates ON — compact row height fits more items; 'Yesterday' and 'Today' are faster to scan than absolute dates"
    "finder_toolbar|finder|Show Finder toolbar — keeps Back/Forward, View switcher, and the search field visible; hiding it is a common accidental state that breaks navigation"
    "finder_sidebar|finder|Show Finder sidebar with Devices and Places expanded — sidebar bookmarks are the fastest way to navigate; Tags section collapsed as it adds clutter without benefit for most workflows"
    "finder_preview_pane|finder|Show Quick Look preview pane on the right — file contents (images, PDFs, text) are visible without opening the file; saves an open/close cycle when triaging files"
    "finder_tab_bar|finder|Show tab bar in Finder windows — enables Cmd+T to open new tabs in the same window; keeps navigation contained to one window instead of spawning multiple"
    "finder_quicklook_text|finder|Enable text selection in Quick Look — you can copy text from a file preview without fully opening it in an editor"
    "finder_desktop_icons|finder|Show drives and removable media on desktop — mounted external drives, USB sticks, and network shares appear on the desktop for quick access and unmounting"
    "finder_save_panel|finder|Expand Save dialog by default — shows the full directory navigator instead of the one-line filename prompt; prevents saving files in unexpected locations"
    "finder_print_panel|finder|Expand Print dialog by default — shows all print options (pages, orientation, scale) instead of the minimal two-option view"
    "finder_save_to_disk|finder|Save new documents to local disk by default — prevents iCloud from silently uploading new files; documents stay local unless you explicitly move them to iCloud"
    "finder_no_icloud|finder|Remove iCloud Drive from Finder sidebar and Go menu — eliminates iCloud from navigation when not in use; stops Finder offering iCloud as a save destination"
    "finder_terminal_service|finder|Add 'New Terminal at Folder' to right-click Services menu — Ctrl+click any folder to open a Terminal tab there without dragging the path into an existing window"
    "ds_store_network|finder|Stop writing .DS_Store files on network volumes — prevents Finder from creating .DS_Store metadata files on NAS shares and SMB mounts that other OSes see as clutter"
    "ds_store_usb|finder|Stop writing .DS_Store files on USB/external volumes — prevents .DS_Store from appearing on FAT32 and exFAT drives shared with Windows or Linux machines"
    "ds_store_remove|finder|Delete all existing .DS_Store files under home — one-time cleanup of accumulated .DS_Store files; has no ongoing effect (see ds_store_network and ds_store_usb for prevention)"
    # ── ui ──────────────────────────────────────────────────────────────────
    "green_button_maximize|ui|Green button → maximize (fill screen) instead of full-screen — avoids creating a new Space and the Space-switch animation; window fills the display without entering full-screen mode"
    "maximize_shortcut|ui|Add Ctrl+Cmd+M global shortcut to maximize any window — triggers the green button action from the keyboard without reaching for the mouse"
    "widgets_disable|ui|Disable all desktop and Notification Centre widgets — clears ~500 MB RAM used by widget processes; widgets wake periodically to refresh data even when not visible"
    "screenshots|ui|Ensure screenshot shortcuts are registered — confirms Cmd+Shift+3 (full screen), Cmd+Shift+4 (region), and Cmd+Shift+5 (options) are active in AppleSymbolicHotKeys"
    "spotlight_shortcut|ui|Ensure Cmd+Space is registered as the Spotlight/app-launcher shortcut — confirms hotkey 60 is active; can be silently lost when other apps register the same combination"
    "controlcenter_cleanup|ui|Remove orphaned Control Centre status items (Siri, AirDrop, TimeMachine, Weather) — stale menu-bar entries left by disabled features that still occupy menu-bar space and trigger background processes"
    "wallpaper_black|ui|Set solid black wallpaper — eliminates WallpaperAerialsExtension (~131 MB RAM) used for dynamic/aerial wallpapers; a static colour requires zero GPU compositing work"
    "crash_reporter|ui|Suppress CrashReporter dialog — default behaviour pops a blocking 'application quit unexpectedly' dialog for every crash that must be dismissed before work can continue; setting DialogType=none suppresses the popup while crash reports still write to ~/Library/Logs/DiagnosticReports"
    "timezone|ui|Set system timezone to MACHETE_TIMEZONE — ensures logs, file timestamps, and scheduled tasks use the correct local time (edit MACHETE_TIMEZONE at the top of this file)"
    "clock_24hr|ui|Force 24-hour time system-wide — overrides locale; 13:45 instead of 1:45 PM eliminates AM/PM ambiguity in logs, terminals, and all system dialogs"
    "clock_iso_date|ui|Force ISO 8601 date format (yyyy-MM-dd) system-wide — overrides locale-dependent formats like 'May 23, 2026' or '23/05/26'; dates sort correctly as strings and match log output"
    "clock_seconds|ui|Show seconds in the menu bar clock — visible elapsed time without opening another app; useful when timing commands or builds"
    "clock_menubar_format|ui|Menu bar clock format → yyyy-MM-dd HH:mm:ss — combines ISO date and 24-hour time with seconds in a single compact string; consistent with terminal and log timestamps"
    "computer_name|ui|Set computer name to MACHETE_COMPUTER_NAME — sets ComputerName, LocalHostName, HostName, and SMB NetBIOSName in one step (edit MACHETE_COMPUTER_NAME at the top of this file)"
    "night_shift|ui|Enable Night Shift 24/7 — sets a custom schedule from 00:00 to 23:59 with normal warmth (middle of the slider); reduces blue light emission permanently without requiring manual toggling each evening"
    "notifications_disable|ui|Disable ALL notifications system-wide — turns off Notification Centre banners, alerts, badges, and sounds for every app; eliminates all visual and audible interruptions without per-app configuration"
    "login_reopen|ui|Disable 'Reopen windows when logging back in' — prevents macOS from restoring all previously open app windows on login; eliminates the burst of app launches that occurs immediately after every reboot or login"
    "state_restoration|ui|Disable per-app state restoration — prevents apps from restoring their last window state on next launch; eliminates hidden auto-launches triggered by the NSQuitAlwaysKeepsWindows system"
    "saved_state_cleanup|ui|Delete saved application state for Apple bloatware — removes ~/Library/Saved Application State directories for Tips, News, Stocks, TV, Music, and Photos so these apps cannot auto-resume windows on login"
    "widget_cleanup|ui|Remove widget containers for unused Apple apps — deletes ~/Library/Containers entries for Tips, News, Stocks, and Photos widgets that spawn background extension processes even when the parent app is not open"
    # ── power ───────────────────────────────────────────────────────────────
    "power_mode_auto|power|AC power mode → Auto — CPU and GPU boost to full performance under load and throttle back at idle; avoids locking into High Power Mode (wastes energy at idle) or Low Power Mode (caps burst performance)"
    "power_display_sleep_ac|power|AC display sleep → 5 min — display turns off after 5 minutes of inactivity on AC power; saves GPU/display energy without being disruptive during normal work sessions"
    "power_system_sleep_ac|power|AC system sleep → 10 min — the system sleeps 10 minutes after the display sleeps on AC; long enough to avoid interrupting long-running tasks"
    "power_clamshell|power|Enable clamshell operation on AC — acwake=1 keeps the Mac awake and processing when the lid is closed and connected to an external display; prevents sleep-on-lid-close"
    "power_nap_ac|power|Disable Power Nap on AC — Power Nap wakes the system during sleep to check mail, sync iCloud, and run Time Machine backups; disable when those services are not in use to prevent unwanted wakes"
    "power_disk_sleep_ac|power|AC disk sleep → 10 min — internal SSD enters low-power state after 10 minutes idle on AC; on Apple Silicon NVMe the impact is minimal but prevents unnecessary idle power draw"
    "power_display_sleep_bat|power|Battery display sleep → 2 min — display turns off sooner on battery to preserve charge; the display is the largest power consumer on a laptop"
    "power_system_sleep_bat|power|Battery system sleep → 5 min — system sleeps 5 minutes after the display sleeps on battery; aggressive sleep extends battery life during away-from-charger use"
    "power_standby_bat|power|Disable standby on battery — standby causes the system to hibernate (write RAM to disk) after a delay; disabling it keeps the machine in normal sleep and avoids the multi-second wake-from-hibernate delay"
    "power_nap_bat|power|Disable Power Nap on battery — same as power_nap_ac but specifically for battery operation; background syncs and wake events are the largest contributor to unexpected battery drain during sleep"
    "hibernate_mode_ac|power|AC hibernate mode → 0 (RAM-only sleep, no disk image) — default mode 3 writes the full contents of RAM to disk as a safety net before standby; on a 128 GB machine that is a 128 GB SSD write on every sleep cycle; mode 0 keeps RAM powered and skips the write entirely, making wake from sleep instant"
    "wol_ac|power|Disable Wake on LAN on AC — womp=1 keeps a network listener active during sleep so a Magic Packet can remotely wake the machine; if you never use remote wake, this is wasted background activity and a minor security surface"
    # ── network ─────────────────────────────────────────────────────────────
    "tcp_socket_buffer|network|TCP socket buffer → 16 MB (default 4 MB) — larger kernel socket buffer allows the OS to keep more in-flight data per connection; measurably improves throughput on high-bandwidth links like 10 GbE or fast Wi-Fi"
    "tcp_send_recv_space|network|TCP send/receive window → 1 MB per connection (default 128 KB) — larger window means more data can be in transit before waiting for acknowledgement; most impactful on high-latency or high-bandwidth connections"
    "tcp_somaxconn|network|Listen backlog → 2048 connections (default 128) — the kernel queues up to 2048 incoming connections before refusing new ones; relevant when running local dev servers (webpack, vite, http-server) under burst browser load"
    "sysctl_perf|network|Kernel vnode cache → 750 000 entries (default ~263 000) — each open file or directory requires a vnode; raising the limit prevents 'too many open files' errors in large monorepos and stops the kernel from evicting hot cache entries under load"
    "iogpu_wired_limit|network|GPU wired memory cap → installed RAM − 6 GB — iogpu.wired_limit_mb tells the Metal driver the maximum it may wire for GPU use; leaving 6 GB headroom guarantees the kernel always has breathing room for CPU workloads and page tables even when a GPU-heavy app tries to claim all unified memory"
    "sysctl_persist|network|Write all sysctl tuning values to /etc/sysctl.conf — makes the tcp_socket_buffer, tcp_send_recv_space, tcp_somaxconn, sysctl_perf, and iogpu_wired_limit changes survive reboots; without this file all sysctl changes revert on next boot"
    "dns_flush|network|Flush DNS resolver cache — clears stale DNS entries immediately after hosts_telemetry edits /etc/hosts; also useful after changing DNS servers or debugging resolution failures"
    # ── updates ─────────────────────────────────────────────────────────────
    "apple_autoupdate|updates|Disable Apple Software Update auto-check, auto-download, and auto-install — stops background update daemons from waking, downloading large OS packages, and installing without explicit consent; manual updates via System Settings still work"
    "airdrop|updates|Disable AirDrop — stops the discoveryd/mDNS advertising that makes the machine visible to nearby Apple devices; eliminates the background Bluetooth and Wi-Fi scanning AirDrop requires to remain discoverable"
    "handoff_continuity|updates|Disable Handoff and Continuity — stops activity advertising to nearby Apple devices (iPhone, iPad, other Macs); eliminates the Bluetooth LE broadcasts and iCloud polling Handoff uses to surface cross-device suggestions"
    # ── security ────────────────────────────────────────────────────────────
    "smb_guest|security|Disable SMB guest access — prevents unauthenticated connections to any shared folders; any SMB client must supply valid credentials"
    "ssh_server|security|Disable inbound SSH server (sshd) — Remote Login is off so no process listens on port 22; outbound ssh connections you initiate are unaffected"
    "remote_apple_events|security|Disable Remote Apple Events — closes the OSAScriptingDefinition port that allows remote machines to run AppleScript on this Mac; rarely needed and a legacy attack surface"
    "gatekeeper|security|Disable Gatekeeper code-signing checks — allows unsigned and ad-hoc signed binaries to run without Quarantine prompts; intended for dev machines that regularly build and run local unsigned tools"
    "mdns_multicast|security|Suppress mDNS multicast advertising — the machine stops responding to .local name resolution requests from other devices on the LAN; reduces network fingerprinting and lateral discovery"
    "hosts_telemetry|security|Block 11 Apple telemetry hostnames in /etc/hosts via 0.0.0.0 — metrics.icloud.com, xp.apple.com, and similar domains are null-routed at the resolver; stops telemetry at the DNS layer with no firewall required"
    "alf_firewall|security|Enable Application Layer Firewall with stealth mode — blocks unsolicited inbound connections to all apps; stealth mode drops ICMP ping requests so the machine does not respond to network probes"
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
# Confirmation engine
# confirm_item returns:  0 = apply optimized  2 = apply default  1 = skip
# _run_item  returns:    0 = apply optimized  2 = apply default  1 = skip
# ---------------------------------------------------------------------------
_accept_all=false
SPOTLIGHT_CHANGED=false   # set true when any spotlight_* item is applied

confirm_item() {
    local number="$1" key="$2" desc="$3" current_val="$4" default_val="$5" optimized_val="$6"

    if [ "$YES_ALL" = true ] || [ "$_accept_all" = true ]; then
        return 0
    fi

    echo ""
    sep
    printf "  [%d/%d] %s\n" "$number" "${#WORK_LIST[@]}" "$desc"
    printf "  Key:       %s\n" "$key"
    printf "  Current:   %s\n" "${current_val:-(not set)}"
    printf "  Default:   %s\n" "${default_val:-(not set)}"
    printf "  Optimized: %s\n" "${optimized_val:-(not set)}"
    printf "  Apply? [o=optimized / d=default / n=skip / a=all optimized / q=quit]: "

    local ans ans_lower
    read -r ans < /dev/tty
    ans_lower=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
    case "$ans_lower" in
        o|optimized|y|yes)  return 0 ;;
        d|default)          return 2 ;;
        n|no)               return 1 ;;
        a|all)              _accept_all=true; return 0 ;;
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
    local number="$1" key="$2" desc="$3" current_val="$4" default_val="$5" optimized_val="$6"
    printf "  [%3d/%d] %-35s | Current: %-20s Default: %-20s Optimized: %s\n" \
        "$number" "${#WORK_LIST[@]}" "$key" \
        "${current_val:-(not set)}" "${default_val:-(not set)}" "${optimized_val:-(not set)}"
}

# ---------------------------------------------------------------------------
# APPLY FUNCTIONS — one per optimization key
# Each: reads current value, calls confirm_item, applies if confirmed
# _run_item return codes:  0 = apply optimized  2 = apply default  1 = skip
# ---------------------------------------------------------------------------

_run_item() {
    local num="$1" key="$2" desc="$3"
    shift 3
    local current="${1:-}" default="${2:-}" optimized="${3:-}"

    if [ "$DRY_RUN" = true ]; then
        dry_item "$num" "$key" "$desc" "$current" "$default" "$optimized"
        return 1   # dry-run: never proceed to write
    fi

    confirm_item "$num" "$key" "$desc" "$current" "$default" "$optimized"
    return $?
}

# ── INPUT ──────────────────────────────────────────────────────────────────

apply_key_repeat_rate() {
    local num="$1" desc="$2"
    local current default="6" optimized="1"
    current=$(dfw read NSGlobalDomain KeyRepeat 2>/dev/null || echo "(not set)")
    _run_item "$num" "key_repeat_rate" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain KeyRepeat 2>/dev/null || true
        ok "KeyRepeat reset to macOS default (6)"
    else
        dfw write NSGlobalDomain KeyRepeat -int 1
        ok "KeyRepeat = 1  (rollback: defaults delete NSGlobalDomain KeyRepeat)"
    fi
}

apply_key_repeat_delay() {
    local num="$1" desc="$2"
    local current default="25" optimized="10"
    current=$(dfw read NSGlobalDomain InitialKeyRepeat 2>/dev/null || echo "(not set)")
    _run_item "$num" "key_repeat_delay" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain InitialKeyRepeat 2>/dev/null || true
        ok "InitialKeyRepeat reset to macOS default (25)"
    else
        dfw write NSGlobalDomain InitialKeyRepeat -int 10
        ok "InitialKeyRepeat = 10"
    fi
}

apply_press_and_hold() {
    local num="$1" desc="$2"
    local current default="true" optimized="false"
    current=$(dfw read NSGlobalDomain ApplePressAndHoldEnabled 2>/dev/null || echo "(not set)")
    _run_item "$num" "press_and_hold" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain ApplePressAndHoldEnabled 2>/dev/null || true
        ok "ApplePressAndHoldEnabled reset to macOS default (true)"
    else
        dfw write NSGlobalDomain ApplePressAndHoldEnabled -bool false
        ok "PressAndHold = false"
    fi
}

apply_touchid_sudo() {
    local num="$1" desc="$2"
    local PAM_FILE="/etc/pam.d/sudo_local"
    local PAM_LINE="auth       sufficient     pam_tid.so"
    local current default="not present" optimized="pam_tid.so added to $PAM_FILE"

    if [ -f "$PAM_FILE" ] && grep -q "pam_tid.so" "$PAM_FILE" 2>/dev/null; then
        current="already enabled"
    else
        current="not enabled"
    fi
    _run_item "$num" "touchid_sudo" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        # Restore default: remove pam_tid.so line
        if [ -f "$PAM_FILE" ]; then
            local tmp; tmp=$(mktemp)
            grep -v "pam_tid.so" "$PAM_FILE" > "$tmp"
            sudo cp "$tmp" "$PAM_FILE"; rm -f "$tmp"
        fi
        ok "Touch ID sudo line removed from $PAM_FILE"
    else
        if ! grep -q "pam_tid.so" "$PAM_FILE" 2>/dev/null; then
            if [ ! -f "$PAM_FILE" ]; then
                printf "# sudo_local: managed by optimizations.sh\n%s\n" "$PAM_LINE" \
                    | sudo tee "$PAM_FILE" > /dev/null
            else
                local tmp; tmp=$(mktemp)
                awk -v line="$PAM_LINE" '
                    !inserted && /^auth/ { print line; inserted=1 }
                    { print }
                    END { if (!inserted) print line }
                ' "$PAM_FILE" > "$tmp"
                sudo cp "$tmp" "$PAM_FILE"; rm -f "$tmp"
            fi
        fi
        ok "Touch ID sudo enabled in $PAM_FILE"
    fi
}

apply_text_substitution() {
    local num="$1" desc="$2"
    local _sq _sd _ac _ps
    _sq=$(dfw read NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled 2>/dev/null || echo "(not set — ON)")
    _sd=$(dfw read NSGlobalDomain NSAutomaticDashSubstitutionEnabled  2>/dev/null || echo "(not set — ON)")
    _ac=$(dfw read NSGlobalDomain NSAutomaticCapitalizationEnabled    2>/dev/null || echo "(not set — ON)")
    _ps=$(dfw read NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled 2>/dev/null || echo "(not set — ON)")
    local current="quotes=${_sq} dashes=${_sd} caps=${_ac} period=${_ps}"
    local default="all ON (system defaults)" optimized="all OFF"
    _run_item "$num" "text_substitution" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled  -bool true
        dfw write NSGlobalDomain NSAutomaticDashSubstitutionEnabled   -bool true
        dfw write NSGlobalDomain NSAutomaticCapitalizationEnabled     -bool true
        dfw write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool true
        ok "Text substitutions reset to macOS defaults (all ON)"
    else
        dfw write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled  -bool false
        dfw write NSGlobalDomain NSAutomaticDashSubstitutionEnabled   -bool false
        dfw write NSGlobalDomain NSAutomaticCapitalizationEnabled     -bool false
        dfw write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
        ok "Smart quotes, smart dashes, auto-caps, and period substitution disabled"
    fi
}

apply_sudo_timeout() {
    local num="$1" desc="$2"
    local SUDOERS_FILE="/etc/sudoers.d/sudo_timeout"
    local current default="5 min (system default)" optimized="30 min"
    if [ -f "$SUDOERS_FILE" ]; then
        current=$(grep "timestamp_timeout" "$SUDOERS_FILE" 2>/dev/null | grep -o '[0-9]*' || echo "custom")
        current="${current} min (from $SUDOERS_FILE)"
    else
        current="5 min (default — no sudoers.d file)"
    fi
    _run_item "$num" "sudo_timeout" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo rm -f "$SUDOERS_FILE"
        ok "sudo_timeout file removed — sudo reverts to system default (5 min)"
    else
        # visudo -c validates before installing; write to temp then install
        local _tmp
        _tmp=$(mktemp)
        printf 'Defaults timestamp_timeout=30\n' > "$_tmp"
        if sudo visudo -c -f "$_tmp" > /dev/null 2>&1; then
            sudo cp "$_tmp" "$SUDOERS_FILE"
            sudo chmod 440 "$SUDOERS_FILE"
            ok "sudo timestamp_timeout = 30 min (written to $SUDOERS_FILE)"
        else
            warn "visudo validation failed — sudo_timeout not applied"
        fi
        rm -f "$_tmp"
    fi
}

# ── TRACKPAD ───────────────────────────────────────────────────────────────

apply_trackpad_speed() {
    local num="$1" desc="$2"
    local current default="1.5" optimized="3.0"
    current=$(dfw read NSGlobalDomain com.apple.trackpad.scaling 2>/dev/null || echo "(not set)")
    _run_item "$num" "trackpad_speed" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain com.apple.trackpad.scaling -float 1.5
        ok "trackpad.scaling reset to macOS default (1.5)"
    else
        dfw write NSGlobalDomain com.apple.trackpad.scaling -float 3.0
        ok "trackpad.scaling = 3.0"
    fi
}

apply_mouse_speed() {
    local num="$1" desc="$2"
    local current default="1.5" optimized="3.0"
    current=$(dfw read NSGlobalDomain com.apple.mouse.scaling 2>/dev/null || echo "(not set)")
    _run_item "$num" "mouse_speed" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain com.apple.mouse.scaling -float 1.5
        ok "mouse.scaling reset to macOS default (1.5)"
    else
        dfw write NSGlobalDomain com.apple.mouse.scaling -float 3.0
        ok "mouse.scaling = 3.0"
    fi
}

apply_spring_load() {
    local num="$1" desc="$2"
    local current default="0.5 (enabled)" optimized="0.1 (enabled)"
    current=$(dfw read NSGlobalDomain com.apple.springing.delay 2>/dev/null || echo "(not set)")
    _run_item "$num" "spring_load" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain com.apple.springing.delay -float 0.5
        dfw write NSGlobalDomain com.apple.springing.enabled -bool true
        ok "springing.delay reset to macOS default (0.5)"
    else
        dfw write NSGlobalDomain com.apple.springing.delay -float 0.1
        dfw write NSGlobalDomain com.apple.springing.enabled -bool true
        ok "springing.delay = 0.1"
    fi
}

apply_tap_to_click() {
    local num="$1" desc="$2"
    local current default="false" optimized="true"
    current=$(dfw read com.apple.AppleMultitouchTrackpad Clicking 2>/dev/null || echo "(not set)")
    _run_item "$num" "tap_to_click" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.AppleMultitouchTrackpad Clicking -bool false
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool false
        dfw -currentHost write com.apple.AppleMultitouchTrackpad Clicking -bool false
        dfw -currentHost write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool false
        dfw write NSGlobalDomain com.apple.mouse.tapBehavior -int 0
        dfw -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 0
        ok "Tap-to-click reset to macOS default (disabled)"
    else
        dfw write com.apple.AppleMultitouchTrackpad Clicking -bool true
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
        dfw -currentHost write com.apple.AppleMultitouchTrackpad Clicking -bool true
        dfw -currentHost write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
        dfw write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
        dfw -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
        ok "Tap-to-click enabled"
    fi
}

apply_tap_to_drag() {
    local num="$1" desc="$2"
    local current default="false" optimized="true"
    current=$(dfw read com.apple.AppleMultitouchTrackpad Dragging 2>/dev/null || echo "(not set)")
    _run_item "$num" "tap_to_drag" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.AppleMultitouchTrackpad Dragging -bool false
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool false
        dfw -currentHost write com.apple.AppleMultitouchTrackpad Dragging -bool false
        dfw -currentHost write com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool false
        ok "Tap-to-drag reset to macOS default (disabled)"
    else
        dfw write com.apple.AppleMultitouchTrackpad Dragging -bool true
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool true
        dfw -currentHost write com.apple.AppleMultitouchTrackpad Dragging -bool true
        dfw -currentHost write com.apple.driver.AppleBluetoothMultitouch.trackpad Dragging -bool true
        ok "Tap-to-drag enabled"
    fi
}

apply_three_finger_drag() {
    local num="$1" desc="$2"
    local current default="false (disabled)" optimized="true (enabled)"
    current=$(dfw read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag 2>/dev/null || echo "(not set)")
    _run_item "$num" "three_finger_drag" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool false
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool false
        dfw -currentHost write NSGlobalDomain com.apple.trackpad.threeFingerDragGesture -bool false
        dfw write com.apple.universalaccess trackpadThreeFingerDragEnabled -bool false 2>/dev/null || true
        ok "3-finger drag reset to macOS default (disabled)"
    else
        dfw write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerDrag -bool true
        dfw -currentHost write NSGlobalDomain com.apple.trackpad.threeFingerDragGesture -bool true
        dfw write com.apple.universalaccess trackpadThreeFingerDragEnabled -bool true 2>/dev/null || true
        ok "3-finger drag enabled"
    fi
}

apply_three_finger_tap() {
    local num="$1" desc="$2"
    local current default="2 (Look Up)" optimized="0 (disabled)"
    current=$(dfw read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture 2>/dev/null || echo "(not set)")
    _run_item "$num" "three_finger_tap" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture -int 2
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerTapGesture -int 2
        ok "3-finger tap reset to macOS default (Look Up = 2)"
    else
        dfw write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerTapGesture -int 0
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerTapGesture -int 0
        ok "3-finger tap Look Up disabled"
    fi
}

apply_natural_scroll() {
    local num="$1" desc="$2"
    local current default="true (natural)" optimized="false (traditional)"
    current=$(defaults read NSGlobalDomain com.apple.swipescrolldirection 2>/dev/null || echo "(not set)")
    _run_item "$num" "natural_scroll" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain com.apple.swipescrolldirection -bool true
        dfw -currentHost write NSGlobalDomain com.apple.swipescrolldirection -bool true
        ok "Scroll direction reset to macOS default (natural)"
    else
        dfw write NSGlobalDomain com.apple.swipescrolldirection -bool false
        dfw write com.apple.AppleMultitouchTrackpad TrackpadScroll -bool true
        dfw write com.apple.AppleMultitouchTrackpad TrackpadHorizScroll -int 1
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadScroll -bool true
        dfw write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadHorizScroll -int 1
        dfw -currentHost write NSGlobalDomain com.apple.swipescrolldirection -bool false
        ok "Scroll direction = traditional (natural scroll OFF)"
    fi
}

# ── SPOTLIGHT ──────────────────────────────────────────────────────────────

apply_spotlight_boot_volume() {
    local num="$1" desc="$2"
    local current default="enabled on /" optimized="enabled on /"
    current=$(mdutil -s / 2>/dev/null | tr -d '\n' || echo "unknown")
    _run_item "$num" "spotlight_boot_volume" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    if echo "$current" | grep -q "disabled"; then
        sudo mdutil -i on / 2>/dev/null || true
        ok "Spotlight indexing enabled on /"
    else
        ok "Spotlight indexing already enabled on /"
    fi
}

apply_spotlight_external_volumes() {
    local num="$1" desc="$2"
    local current default="enabled on external volumes" optimized="disabled on external volumes"
    current=$(mdutil -s 2>/dev/null | grep -v "^/$" | head -3 | tr '\n' ' ' || echo "(scanning)")
    _run_item "$num" "spotlight_external_volumes" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    local count=0
    while IFS= read -r vol; do
        case "$vol" in /System/Volumes/*) continue ;; esac
        if [ "$_rc" -eq 2 ]; then
            sudo mdutil -i on "$vol" 2>/dev/null && count=$((count+1)) || true
        else
            sudo mdutil -i off "$vol" 2>/dev/null && count=$((count+1)) || true
        fi
    done < <(mount | grep -E "apfs|hfs" | awk '{print $3}' | grep -v "^/$")
    [ "$_rc" -eq 2 ] && ok "Spotlight re-enabled on $count non-boot volume(s)" \
                      || ok "Spotlight disabled on $count non-boot volume(s)"
}

apply_spotlight_exclusions() {
    local num="$1" desc="$2"
    local current default="(no exclusions)" optimized="ExclusionPaths cleared"
    current=$(dfw read com.apple.Spotlight ExclusionPaths 2>/dev/null | head -3 || echo "(none)")
    _run_item "$num" "spotlight_exclusions" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    dfw delete com.apple.Spotlight ExclusionPaths 2>/dev/null || true
    ok "Spotlight ExclusionPaths cleared"
}

apply_spotlight_categories() {
    local num="$1" desc="$2"
    local current default="all 20 categories enabled" optimized="Apps + Calculator + Settings only"
    current=$(dfw read com.apple.Spotlight orderedItems 2>/dev/null | grep 'name = ' | tr -d ' "' | head -5 | tr '\n' ',' || echo "(not set)")
    _run_item "$num" "spotlight_categories" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.Spotlight orderedItems 2>/dev/null || true
        ok "Spotlight categories reset to macOS default (all enabled)"
    else
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
        ok "Spotlight categories set to Apps + Calculator + Settings"
    fi
    launchctl kickstart -k "gui/$REAL_UID/com.apple.Spotlight" 2>/dev/null || \
        killall Spotlight 2>/dev/null || true
}

apply_spotlight_siri() {
    local num="$1" desc="$2"
    local current default="true (Siri suggestions on)" optimized="false"
    current=$(dfw read com.apple.Spotlight SiriSuggestionsEnabled 2>/dev/null || echo "(not set)")
    _run_item "$num" "spotlight_siri" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.Spotlight SiriSuggestionsEnabled -bool true
        dfw write com.apple.Spotlight ShowSiriSuggestionsInSpotlight -bool true
        dfw write com.apple.lookup.shared LookupSuggestionsDisabled -bool false 2>/dev/null || true
        ok "Siri suggestions in Spotlight reset to macOS default (enabled)"
    else
        dfw write com.apple.Spotlight SiriSuggestionsEnabled -bool false
        dfw write com.apple.Spotlight ShowSiriSuggestionsInSpotlight -bool false
        dfw write com.apple.lookup.shared LookupSuggestionsDisabled -bool true 2>/dev/null || true
        ok "Siri suggestions in Spotlight disabled"
    fi
}

apply_spotlight_pref_rules() {
    local num="$1" desc="$2"
    local current default="(populated by system)" optimized="EnabledPreferenceRules deleted"
    current=$(dfw read com.apple.Spotlight EnabledPreferenceRules 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    current="${current} entries"
    _run_item "$num" "spotlight_pref_rules" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    SPOTLIGHT_CHANGED=true
    dfw delete com.apple.Spotlight EnabledPreferenceRules 2>/dev/null || true
    ok "Spotlight EnabledPreferenceRules purged"
}

# ── ANIMATIONS ─────────────────────────────────────────────────────────────

apply_window_animations() {
    local num="$1" desc="$2"
    local current default="true" optimized="false"
    current=$(dfw read NSGlobalDomain NSAutomaticWindowAnimationsEnabled 2>/dev/null || echo "(not set)")
    _run_item "$num" "window_animations" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain NSAutomaticWindowAnimationsEnabled 2>/dev/null || true
        ok "NSAutomaticWindowAnimationsEnabled reset to macOS default (true)"
    else
        dfw write NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
        ok "NSAutomaticWindowAnimationsEnabled = false"
    fi
}

apply_window_resize_time() {
    local num="$1" desc="$2"
    local current default="0.2" optimized="0.001"
    current=$(dfw read NSGlobalDomain NSWindowResizeTime 2>/dev/null || echo "(not set)")
    _run_item "$num" "window_resize_time" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain NSWindowResizeTime 2>/dev/null || true
        ok "NSWindowResizeTime reset to macOS default (0.2)"
    else
        dfw write NSGlobalDomain NSWindowResizeTime -float 0.001
        ok "NSWindowResizeTime = 0.001"
    fi
}

apply_scroll_animation() {
    local num="$1" desc="$2"
    local current default="true" optimized="false"
    current=$(dfw read NSGlobalDomain NSScrollAnimationEnabled 2>/dev/null || echo "(not set)")
    _run_item "$num" "scroll_animation" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain NSScrollAnimationEnabled 2>/dev/null || true
        ok "NSScrollAnimationEnabled reset to macOS default (true)"
    else
        dfw write NSGlobalDomain NSScrollAnimationEnabled -bool false
        ok "NSScrollAnimationEnabled = false"
    fi
}

apply_rubber_band() {
    local num="$1" desc="$2"
    local current default="true" optimized="false"
    current=$(dfw read -g NSScrollViewRubberbanding 2>/dev/null || echo "(not set)")
    _run_item "$num" "rubber_band" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete -g NSScrollViewRubberbanding 2>/dev/null || true
        ok "NSScrollViewRubberbanding reset to macOS default (true)"
    else
        dfw write -g NSScrollViewRubberbanding -bool false
        ok "NSScrollViewRubberbanding = false"
    fi
}

apply_reduce_motion() {
    local num="$1" desc="$2"
    local current default="false" optimized="true"
    current=$(dfw read com.apple.universalaccess reduceMotion 2>/dev/null || echo "(not set)")
    _run_item "$num" "reduce_motion" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.universalaccess reduceMotion -bool false
        ok "reduceMotion reset to macOS default (false)"
    else
        dfw write com.apple.universalaccess reduceMotion -bool true
        ok "reduceMotion = true"
    fi
}

apply_desktop_tinting() {
    local num="$1" desc="$2"
    local current default="false (tinting on)" optimized="true (tinting reduced)"
    current=$(dfw read NSGlobalDomain AppleReduceDesktopTinting 2>/dev/null || echo "(not set)")
    _run_item "$num" "desktop_tinting" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain AppleReduceDesktopTinting 2>/dev/null || true
        ok "AppleReduceDesktopTinting reset to macOS default (false)"
    else
        dfw write NSGlobalDomain AppleReduceDesktopTinting -bool true
        ok "AppleReduceDesktopTinting = true"
    fi
}

apply_menubar_blur() {
    local num="$1" desc="$2"
    local current default="true (blur on)" optimized="false (no blur)"
    current=$(dfw read NSGlobalDomain SLSMenuBarUseBlurredAppearance 2>/dev/null || echo "(not set)")
    _run_item "$num" "menubar_blur" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain SLSMenuBarUseBlurredAppearance 2>/dev/null || true
        ok "SLSMenuBarUseBlurredAppearance reset to macOS default (true)"
    else
        dfw write NSGlobalDomain SLSMenuBarUseBlurredAppearance -bool false
        ok "SLSMenuBarUseBlurredAppearance = false"
    fi
}

# ── DOCK ───────────────────────────────────────────────────────────────────

apply_dock_autohide() {
    local num="$1" desc="$2"
    local current default="false (always visible)" optimized="true (auto-hide)"
    current=$(dfw read com.apple.dock autohide 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_autohide" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.dock autohide -bool false
        ok "Dock autohide reset to macOS default (false)"
    else
        dfw write com.apple.dock autohide -bool true
        ok "Dock autohide = true"
    fi
}

apply_dock_autohide_delay() {
    local num="$1" desc="$2"
    local current default="0.5" optimized="0"
    current=$(dfw read com.apple.dock autohide-delay 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_autohide_delay" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.dock autohide-delay 2>/dev/null || true
        ok "autohide-delay reset to macOS default (0.5)"
    else
        dfw write com.apple.dock autohide-delay -float 0
        ok "autohide-delay = 0"
    fi
}

apply_dock_autohide_animation() {
    local num="$1" desc="$2"
    local current default="0.5" optimized="0.15 (fast snap)"
    current=$(dfw read com.apple.dock autohide-time-modifier 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_autohide_animation" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.dock autohide-time-modifier 2>/dev/null || true
        ok "autohide-time-modifier reset to macOS default (0.5)"
    else
        dfw write com.apple.dock autohide-time-modifier -float 0.15
        ok "autohide-time-modifier = 0.15"
    fi
}

apply_dock_launch_animation() {
    local num="$1" desc="$2"
    local current default="true (bounce on launch)" optimized="false"
    current=$(dfw read com.apple.dock launchanim 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_launch_animation" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.dock launchanim 2>/dev/null || true
        ok "launchanim reset to macOS default (true)"
    else
        dfw write com.apple.dock launchanim -bool false
        ok "launchanim = false"
    fi
}

apply_dock_no_bounce() {
    local num="$1" desc="$2"
    local current default="false (bouncing allowed)" optimized="true (bouncing disabled)"
    current=$(dfw read com.apple.dock no-bouncing 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_no_bounce" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.dock no-bouncing -bool false
        ok "no-bouncing reset to macOS default (false)"
    else
        dfw write com.apple.dock no-bouncing -bool true
        ok "no-bouncing = true"
    fi
}

apply_dock_expose_animation() {
    local num="$1" desc="$2"
    local current default="0.1" optimized="0"
    current=$(dfw read com.apple.dock expose-animation-duration 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_expose_animation" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.dock expose-animation-duration 2>/dev/null || true
        ok "expose-animation-duration reset to macOS default (0.1)"
    else
        dfw write com.apple.dock expose-animation-duration -float 0
        ok "expose-animation-duration = 0"
    fi
}

apply_dock_minimize_to_app() {
    local num="$1" desc="$2"
    local current default="false (separate Dock slot)" optimized="true (minimize into app icon)"
    current=$(dfw read com.apple.dock minimize-to-application 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_minimize_to_app" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.dock minimize-to-application -bool false
        ok "minimize-to-application reset to macOS default (false)"
    else
        dfw write com.apple.dock minimize-to-application -bool true
        ok "minimize-to-application = true"
    fi
}

apply_dock_minimize_effect() {
    local num="$1" desc="$2"
    local current default="genie" optimized="scale"
    current=$(dfw read com.apple.dock mineffect 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_minimize_effect" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.dock mineffect -string "genie"
        ok "mineffect reset to macOS default (genie)"
    else
        dfw write com.apple.dock mineffect -string "scale"
        ok "mineffect = scale"
    fi
}

apply_dock_space_animation() {
    local num="$1" desc="$2"
    local current default="false (swoosh animation on)" optimized="true (animation off)"
    current=$(dfw read com.apple.dock workspaces-swoosh-animation-off 2>/dev/null || echo "(not set)")
    _run_item "$num" "dock_space_animation" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.dock workspaces-swoosh-animation-off -bool false
        ok "workspaces-swoosh-animation-off reset to macOS default (false)"
    else
        dfw write com.apple.dock workspaces-swoosh-animation-off -bool true
        ok "workspaces-swoosh-animation-off = true"
    fi
}

apply_dock_launchpad_animation() {
    local num="$1" desc="$2"
    local _show _hide
    _show=$(dfw read com.apple.dock springboard-show-duration 2>/dev/null || echo "(not set)")
    _hide=$(dfw read com.apple.dock springboard-hide-duration 2>/dev/null || echo "(not set)")
    local current="show=${_show} hide=${_hide}" default="show=0.4 hide=0.4" optimized="show=0 hide=0"
    _run_item "$num" "dock_launchpad_animation" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.dock springboard-show-duration 2>/dev/null || true
        dfw delete com.apple.dock springboard-hide-duration 2>/dev/null || true
        ok "Launchpad animation reset to macOS default"
    else
        dfw write com.apple.dock springboard-show-duration -float 0
        dfw write com.apple.dock springboard-hide-duration -float 0
        ok "Launchpad animation = 0/0"
    fi
}

apply_dock_strip() {
    local num="$1" desc="$2"
    local app_names=()
    for _app in "${MACHETE_DOCK_APPS[@]}"; do
        app_names+=("$(basename "$_app" .app)")
    done
    local apps_label
    apps_label=$(IFS='+'; echo "${app_names[*]}")
    local current default="Apple default apps" optimized="$apps_label only"
    current=$(dfw read com.apple.dock persistent-apps 2>/dev/null | grep '"tile-type"' | wc -l | tr -d ' ' || echo "?")
    current="${current} pinned apps"
    _run_item "$num" "dock_strip" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        # Restore default: clear custom strip so Dock reverts to system defaults on next login
        dfw delete com.apple.dock persistent-apps 2>/dev/null || true
        dfw write com.apple.dock show-recents -bool true
        ok "Dock persistent-apps cleared (will restore system defaults on next Dock restart)"
    else
        dfw write com.apple.dock persistent-apps -array
        for _app in "${MACHETE_DOCK_APPS[@]}"; do
            local _url
            _url="file://$(url_encode "$_app")/"
            dfw write com.apple.dock persistent-apps -array-add \
                "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>${_url}</string><key>_CFURLStringType</key><integer>15</integer></dict></dict><key>tile-type</key><string>file-tile</string></dict>"
        done
        dfw write com.apple.dock show-recents -bool false
        ok "Dock stripped to: $apps_label"
    fi
}

apply_hot_corners() {
    local num="$1" desc="$2"
    local _tl _tr _bl _br
    _tl=$(dfw read com.apple.dock wvous-tl-corner 2>/dev/null || echo "0")
    _tr=$(dfw read com.apple.dock wvous-tr-corner 2>/dev/null || echo "0")
    _bl=$(dfw read com.apple.dock wvous-bl-corner 2>/dev/null || echo "0")
    _br=$(dfw read com.apple.dock wvous-br-corner 2>/dev/null || echo "0")
    local current="tl=${_tl} tr=${_tr} bl=${_bl} br=${_br}" default="all 0 (disabled)" optimized="all 0 (disabled)"
    _run_item "$num" "hot_corners" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    for corner in tl tr bl br; do
        dfw write com.apple.dock "wvous-${corner}-corner"   -int 0
        dfw write com.apple.dock "wvous-${corner}-modifier" -int 0
    done
    ok "All hot corners disabled"
}

# ── FINDER ─────────────────────────────────────────────────────────────────

apply_finder_animations() {
    local num="$1" desc="$2"
    local current default="false (animations on)" optimized="true (animations off)"
    current=$(dfw read com.apple.finder DisableAllAnimations 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_animations" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder DisableAllAnimations -bool false
        dfw write com.apple.finder AnimateWindowZoom -bool true
        ok "Finder animations reset to macOS default (enabled)"
    else
        dfw write com.apple.finder DisableAllAnimations -bool true
        dfw write com.apple.finder AnimateWindowZoom -bool false
        ok "Finder animations disabled"
    fi
}

apply_finder_hidden_files() {
    local num="$1" desc="$2"
    local current default="false (hidden files concealed)" optimized="true (show all)"
    current=$(dfw read com.apple.finder AppleShowAllFiles 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_hidden_files" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder AppleShowAllFiles -bool false
        ok "AppleShowAllFiles reset to macOS default (false)"
    else
        dfw write com.apple.finder AppleShowAllFiles -bool true
        ok "AppleShowAllFiles = true"
    fi
}

apply_finder_extensions() {
    local num="$1" desc="$2"
    local current default="false (extensions hidden)" optimized="true (always show)"
    current=$(dfw read NSGlobalDomain AppleShowAllExtensions 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_extensions" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain AppleShowAllExtensions -bool false
        ok "AppleShowAllExtensions reset to macOS default (false)"
    else
        dfw write NSGlobalDomain AppleShowAllExtensions -bool true
        ok "AppleShowAllExtensions = true"
    fi
}

apply_finder_path_bar() {
    local num="$1" desc="$2"
    local current default="false (hidden)" optimized="true (shown)"
    current=$(dfw read com.apple.finder ShowPathbar 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_path_bar" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder ShowPathbar -bool false
        ok "ShowPathbar reset to macOS default (false)"
    else
        dfw write com.apple.finder ShowPathbar -bool true
        ok "ShowPathbar = true"
    fi
}

apply_finder_status_bar() {
    local num="$1" desc="$2"
    local current default="false (hidden)" optimized="true (shown)"
    current=$(dfw read com.apple.finder ShowStatusBar 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_status_bar" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder ShowStatusBar -bool false
        ok "ShowStatusBar reset to macOS default (false)"
    else
        dfw write com.apple.finder ShowStatusBar -bool true
        ok "ShowStatusBar = true"
    fi
}

apply_finder_posix_title() {
    local num="$1" desc="$2"
    local current default="false (hidden)" optimized="true (shown)"
    current=$(dfw read com.apple.finder _FXShowPosixPathInTitle 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_posix_title" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder _FXShowPosixPathInTitle -bool false
        ok "_FXShowPosixPathInTitle reset to macOS default (false)"
    else
        dfw write com.apple.finder _FXShowPosixPathInTitle -bool true
        ok "_FXShowPosixPathInTitle = true"
    fi
}

apply_finder_no_ext_warning() {
    local num="$1" desc="$2"
    local current default="true (warn on change)" optimized="false (no warning)"
    current=$(dfw read com.apple.finder FXEnableExtensionChangeWarning 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_no_ext_warning" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder FXEnableExtensionChangeWarning -bool true
        ok "FXEnableExtensionChangeWarning reset to macOS default (true)"
    else
        dfw write com.apple.finder FXEnableExtensionChangeWarning -bool false
        ok "FXEnableExtensionChangeWarning = false"
    fi
}

apply_finder_no_trash_warning() {
    local num="$1" desc="$2"
    local current default="true (warn on empty)" optimized="false (no warning)"
    current=$(dfw read com.apple.finder WarnOnEmptyTrash 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_no_trash_warning" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder WarnOnEmptyTrash -bool true
        ok "WarnOnEmptyTrash reset to macOS default (true)"
    else
        dfw write com.apple.finder WarnOnEmptyTrash -bool false
        ok "WarnOnEmptyTrash = false"
    fi
}

apply_finder_search_current() {
    local num="$1" desc="$2"
    local current default="SCev (search everywhere)" optimized="SCcf (current folder)"
    current=$(dfw read com.apple.finder FXDefaultSearchScope 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_search_current" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder FXDefaultSearchScope -string "SCev"
        ok "FXDefaultSearchScope reset to macOS default (SCev)"
    else
        dfw write com.apple.finder FXDefaultSearchScope -string "SCcf"
        ok "FXDefaultSearchScope = SCcf"
    fi
}

apply_finder_folders_first() {
    local num="$1" desc="$2"
    local current default="false (mixed sort)" optimized="true (folders first)"
    current=$(dfw read com.apple.finder _FXSortFoldersFirst 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_folders_first" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder _FXSortFoldersFirst -bool false
        dfw write com.apple.finder _FXSortFoldersFirstOnDesktop -bool false
        ok "_FXSortFoldersFirst reset to macOS default (false)"
    else
        dfw write com.apple.finder _FXSortFoldersFirst -bool true
        dfw write com.apple.finder _FXSortFoldersFirstOnDesktop -bool true
        ok "_FXSortFoldersFirst = true"
    fi
}

apply_finder_home_default() {
    local num="$1" desc="$2"
    local current default="PfCm (Computer/Recents)" optimized="PfHm (home folder)"
    current=$(dfw read com.apple.finder NewWindowTarget 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_home_default" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder NewWindowTarget -string "PfCm"
        dfw delete com.apple.finder NewWindowTargetPath 2>/dev/null || true
        ok "NewWindowTarget reset to macOS default (PfCm)"
    else
        dfw write com.apple.finder NewWindowTarget -string "PfHm"
        dfw write com.apple.finder NewWindowTargetPath -string "file://$REAL_HOME/"
        ok "NewWindowTarget = PfHm"
    fi
}

apply_finder_list_view() {
    local num="$1" desc="$2"
    local current default="icnv (icon view)" optimized="Nlsv (list view)"
    current=$(dfw read com.apple.finder FXPreferredViewStyle 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_list_view" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder FXPreferredViewStyle -string "icnv"
        dfw write com.apple.finder "FK_DefaultViewStyle" -string "icnv" 2>/dev/null || true
        ok "FXPreferredViewStyle reset to macOS default (icnv)"
    else
        dfw write com.apple.finder FXPreferredViewStyle -string "Nlsv"
        dfw write com.apple.finder "FK_DefaultViewStyle" -string "Nlsv" 2>/dev/null || true
        ok "FXPreferredViewStyle = Nlsv (list view)"
    fi
}

apply_finder_list_view_columns() {
    local num="$1" desc="$2"
    local current default="(macOS default columns)" optimized="name+size+dateModified+kind visible"
    current=$(dfw read com.apple.finder FK_StandardViewSettings 2>/dev/null | grep ExtendedListViewSettingsV2 | head -1 || echo "(not set)")
    _run_item "$num" "finder_list_view_columns" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.finder FK_StandardViewSettings 2>/dev/null || true
        ok "Finder list view columns reset to macOS default"
    else
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
    fi
}

apply_finder_list_view_icon_size() {
    local num="$1" desc="$2"
    local current default="iconSize=16 textSize=13 useRelativeDates=false" optimized="iconSize=16 textSize=13 useRelativeDates=true"
    current=$(dfw read com.apple.finder StandardViewSettings 2>/dev/null | grep iconSize | head -1 | tr -d ' ' || echo "(not set)")
    _run_item "$num" "finder_list_view_icon_size" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder StandardViewSettings -dict-add ListViewSettings \
            "{ calculateAllSizes = 0; iconSize = 16; showIconPreview = 1; sortColumn = name; textSize = 13; useRelativeDates = 0; viewOptionsVersion = 1; }"
        ok "List view icon size reset to macOS default"
    else
        dfw write com.apple.finder StandardViewSettings -dict-add ListViewSettings \
            "{ calculateAllSizes = 0; iconSize = 16; showIconPreview = 1; sortColumn = name; textSize = 13; useRelativeDates = 1; viewOptionsVersion = 1; }"
        ok "List view: 16px icons, 13pt text, relative dates"
    fi
}

apply_finder_toolbar() {
    local num="$1" desc="$2"
    local current default="1 (shown)" optimized="1 (shown)"
    current=$(dfw read com.apple.finder "NSToolbar Configuration Browser" 2>/dev/null | grep "TB Is Shown" | tr -d ' ' || echo "(not set)")
    _run_item "$num" "finder_toolbar" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder "NSToolbar Configuration Browser" -dict-add "TB Is Shown" -int 1
    ok "Finder toolbar visible"
}

apply_finder_sidebar() {
    local num="$1" desc="$2"
    local current default="true (shown)" optimized="true (shown, sections expanded)"
    current=$(dfw read com.apple.finder ShowSidebar 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_sidebar" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.finder ShowSidebar -bool true
    dfw write com.apple.finder FK_AppCentricShowSidebar -int 1
    dfw write com.apple.finder SidebarDevicesSectionDisclosedState -bool true
    dfw write com.apple.finder SidebarPlacesSectionDisclosedState  -bool true
    dfw write com.apple.finder SidebarTagsSctionDisclosedState     -bool false
    ok "Finder sidebar shown, Devices+Places expanded, Tags collapsed"
}

apply_finder_preview_pane() {
    local num="$1" desc="$2"
    local current default="false (hidden)" optimized="true (shown)"
    current=$(dfw read com.apple.finder ShowPreviewPane 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_preview_pane" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder ShowPreviewPane -bool false
        ok "ShowPreviewPane reset to macOS default (false)"
    else
        dfw write com.apple.finder ShowPreviewPane -bool true
        ok "Finder preview pane enabled"
    fi
}

apply_finder_tab_bar() {
    local num="$1" desc="$2"
    local current default="false (hidden)" optimized="true (shown)"
    current=$(dfw read com.apple.finder "NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow" 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_tab_bar" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder "NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow" -bool false
        ok "Finder tab bar reset to macOS default (false)"
    else
        dfw write com.apple.finder "NSWindowTabbingShoudShowTabBarKey-com.apple.finder.TBrowserWindow" -bool true
        ok "Finder tab bar enabled"
    fi
}

apply_finder_terminal_service() {
    local num="$1" desc="$2"
    local current default="0 Terminal services registered" optimized="New Terminal at Folder + Tab enabled"
    current=$(sudo -u "$REAL_USER" defaults read pbs NSServicesStatus 2>/dev/null | grep -c "com.apple.Terminal" || echo "0")
    current="${current} Terminal services registered"
    _run_item "$num" "finder_terminal_service" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo -u "$REAL_USER" defaults delete pbs NSServicesStatus 2>/dev/null || true
        /System/Library/CoreServices/pbs -flush 2>/dev/null || killall pbs 2>/dev/null || true
        ok "Terminal services removed from pbs"
    else
        sudo -u "$REAL_USER" defaults write pbs NSServicesStatus -dict-add \
            "com.apple.Terminal - New Terminal at Folder - newTerminalAtFolder" \
            '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
        sudo -u "$REAL_USER" defaults write pbs NSServicesStatus -dict-add \
            "com.apple.Terminal - New Terminal Tab at Folder - newTerminalTabAtFolder" \
            '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
        /System/Library/CoreServices/pbs -flush 2>/dev/null || killall pbs 2>/dev/null || true
        ok "Terminal services enabled — right-click folder → Services → New Terminal at Folder"
    fi
}

apply_finder_quicklook_text() {
    local num="$1" desc="$2"
    local current default="false (text selection off)" optimized="true (text selection on)"
    current=$(dfw read com.apple.finder QLEnableTextSelection 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_quicklook_text" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder QLEnableTextSelection -bool false
        ok "QLEnableTextSelection reset to macOS default (false)"
    else
        dfw write com.apple.finder QLEnableTextSelection -bool true
        ok "QLEnableTextSelection = true"
    fi
}

apply_finder_desktop_icons() {
    local num="$1" desc="$2"
    local _hd _ext _rem _srv
    _hd=$(dfw read com.apple.finder ShowHardDrivesOnDesktop 2>/dev/null || echo "(not set)")
    _ext=$(dfw read com.apple.finder ShowExternalHardDrivesOnDesktop 2>/dev/null || echo "(not set)")
    _rem=$(dfw read com.apple.finder ShowRemovableMediaOnDesktop 2>/dev/null || echo "(not set)")
    _srv=$(dfw read com.apple.finder ShowMountedServersOnDesktop 2>/dev/null || echo "(not set)")
    local current="hd=${_hd} ext=${_ext} rem=${_rem} srv=${_srv}" default="all false" optimized="all true"
    _run_item "$num" "finder_desktop_icons" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=false || _val=true
    dfw write com.apple.finder ShowHardDrivesOnDesktop -bool "$_val"
    dfw write com.apple.finder ShowExternalHardDrivesOnDesktop -bool "$_val"
    dfw write com.apple.finder ShowRemovableMediaOnDesktop -bool "$_val"
    dfw write com.apple.finder ShowMountedServersOnDesktop -bool "$_val"
    ok "Desktop drive icons set to ${_val}"
}

apply_finder_save_panel() {
    local num="$1" desc="$2"
    local current default="false (collapsed)" optimized="true (expanded)"
    current=$(dfw read NSGlobalDomain NSNavPanelExpandedStateForSaveMode 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_save_panel" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=false || _val=true
    dfw write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool "$_val"
    dfw write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool "$_val"
    ok "Save panel expanded = ${_val}"
}

apply_finder_print_panel() {
    local num="$1" desc="$2"
    local current default="false (collapsed)" optimized="true (expanded)"
    current=$(dfw read NSGlobalDomain PMPrintingExpandedStateForPrint 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_print_panel" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=false || _val=true
    dfw write NSGlobalDomain PMPrintingExpandedStateForPrint -bool "$_val"
    dfw write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool "$_val"
    ok "Print panel expanded = ${_val}"
}

apply_finder_save_to_disk() {
    local num="$1" desc="$2"
    local current default="true (save to iCloud)" optimized="false (save to disk)"
    current=$(dfw read NSGlobalDomain NSDocumentSaveNewDocumentsToCloud 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_save_to_disk" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool true
        ok "NSDocumentSaveNewDocumentsToCloud reset to macOS default (true)"
    else
        dfw write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
        ok "NSDocumentSaveNewDocumentsToCloud = false"
    fi
}

apply_finder_no_icloud() {
    local num="$1" desc="$2"
    local current default="true (iCloud shown)" optimized="false (iCloud hidden)"
    current=$(dfw read com.apple.finder ShowiCloudDriveInFinder 2>/dev/null || echo "(not set)")
    _run_item "$num" "finder_no_icloud" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.finder ShowiCloudDriveInFinder -bool true
        dfw write com.apple.finder ShowiCloudDesktopOnFinder -bool true
        ok "iCloud Drive shown in Finder (macOS default)"
    else
        dfw write com.apple.finder ShowiCloudDriveInFinder -bool false
        dfw write com.apple.finder ShowiCloudDesktopOnFinder -bool false
        ok "iCloud Drive hidden from Finder"
    fi
}

apply_ds_store_network() {
    local num="$1" desc="$2"
    local current default="false (.DS_Store written)" optimized="true (.DS_Store suppressed)"
    current=$(dfw read com.apple.desktopservices DSDontWriteNetworkStores 2>/dev/null || echo "(not set)")
    _run_item "$num" "ds_store_network" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=false || _val=true
    dfw write com.apple.desktopservices DSDontWriteNetworkStores -bool "$_val"
    ok "DSDontWriteNetworkStores = ${_val}"
}

apply_ds_store_usb() {
    local num="$1" desc="$2"
    local current default="false (.DS_Store written)" optimized="true (.DS_Store suppressed)"
    current=$(dfw read com.apple.desktopservices DSDontWriteUSBStores 2>/dev/null || echo "(not set)")
    _run_item "$num" "ds_store_usb" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=false || _val=true
    dfw write com.apple.desktopservices DSDontWriteUSBStores -bool "$_val"
    ok "DSDontWriteUSBStores = ${_val}"
}

apply_ds_store_remove() {
    local num="$1" desc="$2"
    local sample
    sample=$(find "$REAL_HOME" -maxdepth 4 -name ".DS_Store" 2>/dev/null | wc -l | tr -d ' ')
    local current="~${sample}+ .DS_Store files in $REAL_HOME" default="(files present)" optimized="all deleted"
    _run_item "$num" "ds_store_remove" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    # Both 'o' and 'd' delete — there is no meaningful "default" restore action
    local deleted=0
    while IFS= read -r -d "" f; do
        rm -f "$f" 2>/dev/null && deleted=$((deleted + 1)) || true
    done < <(find "$REAL_HOME" -name ".DS_Store" -print0 2>/dev/null)
    ok "Removed $deleted .DS_Store files from $REAL_HOME"
}

# ── UI ─────────────────────────────────────────────────────────────────────

apply_green_button_maximize() {
    local num="$1" desc="$2"
    local current default="automatic (green = fullscreen)" optimized="manual (green = maximize)"
    current=$(dfw read NSGlobalDomain AppleWindowTabbingMode 2>/dev/null || echo "(not set)")
    _run_item "$num" "green_button_maximize" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain AppleWindowTabbingMode -string "automatic"
        ok "AppleWindowTabbingMode reset to macOS default (automatic)"
    else
        dfw write NSGlobalDomain AppleWindowTabbingMode -string "manual"
        ok "AppleWindowTabbingMode = manual"
    fi
}

apply_maximize_shortcut() {
    local num="$1" desc="$2"
    local current default="(none)" optimized="Ctrl+Cmd+M = Zoom"
    current=$(dfw read NSGlobalDomain NSUserKeyEquivalents 2>/dev/null | grep Zoom | tr -d ' ' || echo "(not set)")
    _run_item "$num" "maximize_shortcut" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write NSGlobalDomain NSUserKeyEquivalents -dict-add "Zoom" ""
        ok "Zoom shortcut removed (macOS default = none)"
    else
        dfw write NSGlobalDomain NSUserKeyEquivalents -dict-add "Zoom" '@^m'
        ok "Zoom shortcut = Ctrl+Cmd+M"
    fi
}

apply_widgets_disable() {
    local num="$1" desc="$2"
    local instance_count
    instance_count=$(dfw read com.apple.notificationcenterui widgets 2>/dev/null | grep -c 'bplist' || echo "0")
    local current="${instance_count} active widget instance(s)" default="(system default widgets)" optimized="all widgets disabled"
    _run_item "$num" "widgets_disable" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.notificationcenterui WidgetAllowList 2>/dev/null || true
        dfw delete com.apple.notificationcenterui widgets 2>/dev/null || true
        ok "Widget settings reset to macOS default"
    else
        dfw write com.apple.notificationcenterui WidgetAllowList -array
        dfw write com.apple.notificationcenterui widgets \
            '{ instances = (); DesktopWidgetPlacementStorage = (); vers = 1; }'
        ok "All widgets disabled"
    fi
}

apply_screenshots() {
    local num="$1" desc="$2"
    local current default="keys 28/29/30/31/184 enabled" optimized="keys 28/29/30/31/184 enabled"
    current=$(dfw read com.apple.symbolichotkeys AppleSymbolicHotKeys 2>/dev/null | grep -A2 '"28"' | head -3 || echo "(not set)")
    _run_item "$num" "screenshots" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
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
    local current default="key 60 enabled (Cmd+Space)" optimized="key 60 enabled (Cmd+Space)"
    current=$(dfw read com.apple.symbolichotkeys AppleSymbolicHotKeys 2>/dev/null | grep -A2 '"60"' | head -3 || echo "(not set)")
    _run_item "$num" "spotlight_shortcut" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    dfw write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 60 \
        "{ enabled = 1; value = { parameters = (32, 49, 1048576); type = standard; }; }"
    ok "Cmd+Space spotlight shortcut enabled"
}

apply_controlcenter_cleanup() {
    local num="$1" desc="$2"
    local current default="(varies)" optimized="Siri/AirDrop/FocusModes/ScreenMirroring/TimeMachine/Weather removed"
    current=$(dfw read com.apple.controlcenter 2>/dev/null | grep -c "NSStatusItem" || echo "(not set)")
    current="${current} CC status items"
    _run_item "$num" "controlcenter_cleanup" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    for module in Siri AirDrop FocusModes ScreenMirroring TimeMachine Weather; do
        dfw delete com.apple.controlcenter "NSStatusItem VisibleCC $module" 2>/dev/null || true
    done
    ok "Orphaned Control Center items removed"
}

apply_wallpaper_black() {
    local num="$1" desc="$2"
    local BLACK="/System/Library/Desktop Pictures/Solid Colors/Black.png"
    local current default="(macOS default wallpaper)" optimized="solid black"
    current=$(sudo -u "$REAL_USER" osascript -e 'tell application "System Events" to get picture of desktop 1' 2>/dev/null || echo "(unknown)")
    _run_item "$num" "wallpaper_black" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        warn "Cannot auto-restore wallpaper — set manually: System Settings → Wallpaper"
        return 0
    fi
    if [ -f "$BLACK" ]; then
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
    fi
}

apply_crash_reporter() {
    local num="$1" desc="$2"
    local current default="prompt (blocking dialog on every crash)" optimized="none (silent — reports still written to ~/Library/Logs/DiagnosticReports)"
    current=$(dfw read com.apple.CrashReporter DialogType 2>/dev/null || echo "(not set — defaults to prompt)")
    _run_item "$num" "crash_reporter" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.CrashReporter DialogType 2>/dev/null || true
        ok "CrashReporter reset to macOS default (blocking prompt)"
    else
        dfw write com.apple.CrashReporter DialogType -string "none"
        ok "CrashReporter dialog suppressed (reports still written to DiagnosticReports)"
    fi
}

apply_timezone() {
    local num="$1" desc="$2"
    local current default="(setup assistant selection)" optimized="$MACHETE_TIMEZONE"
    current=$(sudo systemsetup -gettimezone 2>/dev/null | awk '{print $NF}' || echo "unknown")
    _run_item "$num" "timezone" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    # For 'd' we can't know the original default — warn and skip
    if [ "$_rc" -eq 2 ]; then
        warn "Cannot restore timezone default automatically — set in System Settings → General → Date & Time"
        return 0
    fi
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
    local current default="false (12-hour / locale-dependent)" optimized="true (24-hour)"
    current=$(dfw read NSGlobalDomain AppleICUForce24HourTime 2>/dev/null || echo "(not set)")
    _run_item "$num" "clock_24hr" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain AppleICUForce24HourTime 2>/dev/null || true
        ok "AppleICUForce24HourTime reset to macOS default (locale-dependent)"
    else
        dfw write NSGlobalDomain AppleICUForce24HourTime -bool true
        ok "AppleICUForce24HourTime = true"
    fi
}

apply_clock_iso_date() {
    local num="$1" desc="$2"
    local current default="(locale-dependent, e.g. d MMM y)" optimized="yyyy-MM-dd (ISO 8601)"
    current=$(dfw read NSGlobalDomain AppleICUDateFormatStrings 2>/dev/null | grep '"1"' | head -1 || echo "(not set)")
    _run_item "$num" "clock_iso_date" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain AppleICUDateFormatStrings 2>/dev/null || true
        dfw delete NSGlobalDomain AppleICUTimeFormatStrings 2>/dev/null || true
        ok "Date/time format reset to macOS locale default"
    else
        dfw write NSGlobalDomain AppleICUDateFormatStrings -dict \
            1 "yyyy-MM-dd" 2 "yyyy-MM-dd" 3 "yyyy-MM-dd" 4 "yyyy-MM-dd"
        dfw write NSGlobalDomain AppleICUTimeFormatStrings -dict \
            1 "HH:mm:ss" 2 "HH:mm:ss" 3 "HH:mm:ss" 4 "HH:mm:ss"
        ok "Date = yyyy-MM-dd, Time = HH:mm:ss (all ICU levels)"
    fi
}

apply_clock_seconds() {
    local num="$1" desc="$2"
    local current default="false (seconds hidden)" optimized="true (seconds shown)"
    current=$(dfw read com.apple.menuextra.clock ShowSeconds 2>/dev/null || echo "(not set)")
    _run_item "$num" "clock_seconds" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.menuextra.clock ShowSeconds -bool false
        ok "ShowSeconds reset to macOS default (false)"
    else
        dfw write com.apple.menuextra.clock ShowSeconds -bool true
        dfw write com.apple.menuextra.clock Show24Hour -bool true
        ok "Menu bar clock shows seconds"
    fi
}

apply_clock_menubar_format() {
    local num="$1" desc="$2"
    local current default="(locale-dependent, e.g. h:mm a)" optimized="yyyy-MM-dd HH:mm:ss"
    current=$(dfw read com.apple.menuextra.clock DateFormat 2>/dev/null || echo "(not set)")
    _run_item "$num" "clock_menubar_format" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.menuextra.clock DateFormat 2>/dev/null || true
        ok "Menu bar clock format reset to macOS default"
    else
        dfw write com.apple.menuextra.clock DateFormat -string "yyyy-MM-dd HH:mm:ss"
        dfw write com.apple.menuextra.clock ShowAMPM -bool false
        dfw write com.apple.menuextra.clock ShowDate -bool false
        dfw write com.apple.menuextra.clock ShowDayOfWeek -bool false
        ok "Menu bar clock = yyyy-MM-dd HH:mm:ss"
    fi
}

apply_computer_name() {
    local num="$1" desc="$2"
    local NAME="$MACHETE_COMPUTER_NAME"
    local current default="(setup assistant name)" optimized="ComputerName=$NAME LocalHostName=$NAME HostName=$NAME"
    current="ComputerName=$(scutil --get ComputerName 2>/dev/null || echo '?') LocalHostName=$(scutil --get LocalHostName 2>/dev/null || echo '?')"
    _run_item "$num" "computer_name" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        warn "Cannot restore original computer name automatically — set in System Settings → General → Sharing"
        return 0
    fi
    # Prompt for custom name (unless --yes was passed, in which case use MACHETE_COMPUTER_NAME)
    if [ "$YES_ALL" = false ] && [ "$_accept_all" = false ]; then
        printf "  Enter computer name [%s]: " "$NAME"
        local input
        read -r input < /dev/tty
        [ -n "$input" ] && NAME="$input"
    fi
    sudo scutil --set ComputerName  "$NAME"
    sudo scutil --set LocalHostName "$NAME"
    sudo scutil --set HostName      "$NAME"
    sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$NAME"
    ok "Computer name set to $NAME"
}

apply_night_shift() {
    local num="$1" desc="$2"
    local CB_PLIST="/var/root/Library/Preferences/com.apple.CoreBrightness.plist"
    local current default="off (no schedule)" optimized="on 24/7 (schedule 00:00–23:59, normal warmth)"

    # Read current Night Shift status
    if command -v /usr/libexec/PlistBuddy > /dev/null 2>&1 && [ -f "$CB_PLIST" ]; then
        local _ns_enabled
        _ns_enabled=$(/usr/libexec/PlistBuddy -c "Print :CBUser-0:CBBlueLightReductionCCTTargetRaw" "$CB_PLIST" 2>/dev/null || echo "?")
        current="CCT target=${_ns_enabled}"
    else
        current="(cannot read — may need first run)"
    fi

    _run_item "$num" "night_shift" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0

    if [ "$_rc" -eq 2 ]; then
        # Restore default: disable Night Shift schedule
        sudo /usr/libexec/PlistBuddy \
            -c "Set :CBUser-0:CBBlueReductionStatus:AutoBlueReductionEnabled 0" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueReductionEnabled 0" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueReductionMode 0" \
            "$CB_PLIST" 2>/dev/null || true
        sudo killall -HUP corebrightnessd 2>/dev/null || true
        ok "Night Shift disabled (macOS default)"
    else
        # Enable Night Shift 24/7:
        # Mode 2 = custom schedule; schedule from 00:00 to 23:59; max warmth
        # Create entries if they don't exist, then set them
        if [ ! -f "$CB_PLIST" ]; then
            warn "CoreBrightness plist not found at $CB_PLIST — attempting alternative method"
            # Fall back to user-level plist
            CB_PLIST="$REAL_HOME/Library/Preferences/com.apple.CoreBrightness.plist"
        fi

        # Ensure the dictionary structure exists
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0 dict" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus dict" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:AutoBlueReductionEnabled integer 1" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueReductionEnabled integer 1" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueReductionMode integer 2" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueReductionSunScheduleAllowed bool false" "$CB_PLIST" 2>/dev/null || true

        # Set values (in case they already exist)
        sudo /usr/libexec/PlistBuddy \
            -c "Set :CBUser-0:CBBlueReductionStatus:AutoBlueReductionEnabled 1" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueReductionEnabled 1" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueReductionMode 2" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueReductionSunScheduleAllowed false" \
            "$CB_PLIST" 2>/dev/null || true

        # Custom schedule: start at 00:00 (hour=0, minute=0), end at 23:59 (hour=23, minute=59)
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule dict" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:DayStartHour integer 0" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:DayStartMinute integer 0" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:NightStartHour integer 0" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:NightStartMinute integer 0" "$CB_PLIST" 2>/dev/null || true

        sudo /usr/libexec/PlistBuddy \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:DayStartHour 23" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:DayStartMinute 59" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:NightStartHour 0" \
            -c "Set :CBUser-0:CBBlueReductionStatus:BlueLightReductionSchedule:NightStartMinute 0" \
            "$CB_PLIST" 2>/dev/null || true

        # Set normal warmth (CCT target: scale is ~2700 max warmth to ~4000 least warmth; 3400 is middle of slider)
        sudo /usr/libexec/PlistBuddy \
            -c "Add :CBUser-0:CBBlueLightReductionCCTTargetRaw real 3400" "$CB_PLIST" 2>/dev/null || true
        sudo /usr/libexec/PlistBuddy \
            -c "Set :CBUser-0:CBBlueLightReductionCCTTargetRaw 3400" "$CB_PLIST" 2>/dev/null || true

        # Restart CoreBrightness daemon to apply changes
        sudo killall -HUP corebrightnessd 2>/dev/null || \
            sudo launchctl kickstart -k system/com.apple.corebrightnessd 2>/dev/null || true

        ok "Night Shift enabled 24/7 (schedule 00:00–23:59, normal warmth)"
        log "  Note: If Night Shift doesn't activate immediately, toggle it once in System Settings → Displays → Night Shift"
    fi
}

apply_notifications_disable() {
    local num="$1" desc="$2"
    local NC_PREFS="$REAL_HOME/Library/Preferences/com.apple.ncprefs.plist"
    local current default="per-app defaults (banners/alerts enabled)" optimized="all notifications disabled"
    if [ -f "$NC_PREFS" ]; then
        local app_count
        app_count=$(sudo -u "$REAL_USER" /usr/libexec/PlistBuddy -c "Print :apps" "$NC_PREFS" 2>/dev/null | grep -c "Dict" || echo "0")
        current="${app_count} apps with notification settings"
    else
        current="(nc prefs not found)"
    fi
    _run_item "$num" "notifications_disable" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        # Restore default: remove the global disable flag and let per-app defaults apply
        dfw write com.apple.ncprefs content_visibility -dict
        # Re-enable Do Not Disturb schedule removal
        dfw delete com.apple.notificationcenterui dndMirroring 2>/dev/null || true
        dfw delete com.apple.notificationcenterui dndStart 2>/dev/null || true
        dfw delete com.apple.notificationcenterui dndEnd 2>/dev/null || true
        ok "Notification settings reset — per-app defaults restored"
    else
        # Disable notification centre entirely via Do Not Disturb always-on
        # Set DND to cover 00:00 to 23:59 (effectively always on)
        dfw write com.apple.ncprefs dnd_prefs -dict \
            dndDisplayLock -bool true \
            dndDisplaySleep -bool true \
            dndMirrored -bool true \
            facetimeCanBreakDND -bool false \
            repeatedFacetimeCallsBreaksDND -bool false
        # Iterate over all apps in ncprefs and set flags to suppress all notifications
        # flags value 0 = notifications off for that app (no banners, no badges, no sounds)
        if [ -f "$NC_PREFS" ]; then
            local idx=0
            while sudo -u "$REAL_USER" /usr/libexec/PlistBuddy \
                -c "Print :apps:${idx}:bundle-id" "$NC_PREFS" > /dev/null 2>&1; do
                sudo -u "$REAL_USER" /usr/libexec/PlistBuddy \
                    -c "Set :apps:${idx}:flags 0" "$NC_PREFS" 2>/dev/null || true
                idx=$((idx + 1))
            done
            ok "Disabled notifications for $idx apps in $NC_PREFS"
        fi
        # Also set global Do Not Disturb via Notification Center preferences
        dfw write com.apple.notificationcenterui dndMirroring -bool true
        dfw write com.apple.notificationcenterui dndStart -float 0
        dfw write com.apple.notificationcenterui dndEnd -float 1440
        # Disable notification centre widget and banner display
        dfw write com.apple.notificationcenterui bannerTime -int 0
        ok "All notifications disabled (DND always-on + per-app flags zeroed)"
        log "  Note: macOS Focus/DND may need manual confirmation in System Settings → Focus"
    fi
}

apply_login_reopen() {
    local num="$1" desc="$2"
    local current default="true (reopen on login)" optimized="false (no reopen)"
    current=$(dfw read com.apple.loginwindow TALLogoutSavesState 2>/dev/null || echo "(not set)")
    _run_item "$num" "login_reopen" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete com.apple.loginwindow TALLogoutSavesState 2>/dev/null || true
        ok "TALLogoutSavesState reset to macOS default (reopen windows on login)"
    else
        dfw write com.apple.loginwindow TALLogoutSavesState -bool false
        ok "TALLogoutSavesState = false (no windows reopened on login)"
    fi
}

apply_state_restoration() {
    local num="$1" desc="$2"
    local current default="true (apps restore windows)" optimized="false (apps start fresh)"
    current=$(dfw read NSGlobalDomain NSQuitAlwaysKeepsWindows 2>/dev/null || echo "(not set)")
    _run_item "$num" "state_restoration" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw delete NSGlobalDomain NSQuitAlwaysKeepsWindows 2>/dev/null || true
        ok "NSQuitAlwaysKeepsWindows reset to macOS default (restore windows)"
    else
        dfw write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false
        ok "NSQuitAlwaysKeepsWindows = false (apps start fresh)"
    fi
}

apply_saved_state_cleanup() {
    local num="$1" desc="$2"
    local SAVED_STATE_DIR="$REAL_HOME/Library/Saved Application State"
    local TARGETS=(
        "com.apple.Tips.savedState"
        "com.apple.news.savedState"
        "com.apple.stocks.savedState"
        "com.apple.TV.savedState"
        "com.apple.Music.savedState"
        "com.apple.Photos.savedState"
    )
    local found=0
    for t in "${TARGETS[@]}"; do
        [ -d "$SAVED_STATE_DIR/$t" ] && found=$((found + 1))
    done
    local current="$found/${#TARGETS[@]} saved state dirs exist" default="(dirs present)" optimized="all deleted + locked"
    _run_item "$num" "saved_state_cleanup" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        for t in "${TARGETS[@]}"; do
            local _path="$SAVED_STATE_DIR/$t"
            chflags nouchg "$_path" 2>/dev/null || true
            rm -rf "$_path" 2>/dev/null || true
        done
        ok "Saved state dirs removed (unlocked); apps may recreate them"
    else
        local deleted=0
        for t in "${TARGETS[@]}"; do
            local _path="$SAVED_STATE_DIR/$t"
            # Remove existing saved state
            chflags nouchg "$_path" 2>/dev/null || true
            rm -rf "$_path" 2>/dev/null || true
            # Create empty dir and lock it so macOS cannot recreate the state
            sudo -u "$REAL_USER" mkdir -p "$_path"
            chflags uchg "$_path"
            deleted=$((deleted + 1))
        done
        ok "Deleted and locked $deleted saved state dirs (Tips, News, Stocks, TV, Music, Photos)"
    fi
}

apply_widget_cleanup() {
    local num="$1" desc="$2"
    local CONTAINERS_DIR="$REAL_HOME/Library/Containers"
    local TARGETS=(
        "com.apple.tips.Widget"
        "com.apple.news.widget"
        "com.apple.stocks.widget"
        "com.apple.Photos.PhotosReliveWidget"
    )
    local found=0
    for t in "${TARGETS[@]}"; do
        [ -d "$CONTAINERS_DIR/$t" ] && found=$((found + 1))
    done
    local current="$found/${#TARGETS[@]} widget containers exist" default="(containers present)" optimized="all deleted"
    _run_item "$num" "widget_cleanup" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        warn "Cannot auto-restore widget containers — re-add widgets via System Settings → Desktop & Dock → Widgets"
        return 0
    fi
    local removed=0
    for t in "${TARGETS[@]}"; do
        local _path="$CONTAINERS_DIR/$t"
        if [ -d "$_path" ]; then
            rm -rf "$_path" 2>/dev/null && removed=$((removed + 1)) || true
        fi
    done
    ok "Removed $removed widget containers (Tips, News, Stocks, Photos)"
    log "  Note: Widgets may recreate containers on next use; pair with widgets_disable for permanent effect"
}

# ── POWER ──────────────────────────────────────────────────────────────────

apply_power_mode_auto() {
    local num="$1" desc="$2"
    local current default="1 (Auto)" optimized="1 (Auto)"
    current=$(pmset -g | awk '/powermode/{print $2}' || echo "unknown")
    _run_item "$num" "power_mode_auto" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c powermode 1
    ok "AC powermode = 1 (Auto)"
}

apply_power_display_sleep_ac() {
    local num="$1" desc="$2"
    local current default="10 min" optimized="5 min"
    current=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/displaysleep/{print $2; exit}' || echo "?")
    _run_item "$num" "power_display_sleep_ac" "$desc" "${current} min" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    [ "$_rc" -eq 2 ] && sudo pmset -c displaysleep 10 || sudo pmset -c displaysleep 5
    ok "AC displaysleep = $( [ "$_rc" -eq 2 ] && echo 10 || echo 5 )"
}

apply_power_system_sleep_ac() {
    local num="$1" desc="$2"
    local current default="10 min" optimized="10 min"
    current=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/^[ ]+sleep /{print $2; exit}' || echo "?")
    _run_item "$num" "power_system_sleep_ac" "$desc" "${current} min" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c sleep 10
    ok "AC sleep = 10"
}

apply_power_clamshell() {
    local num="$1" desc="$2"
    local _aw _lw _tty
    _aw=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/acwake/{print $2; exit}' || echo "?")
    _lw=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/lidwake/{print $2; exit}' || echo "?")
    _tty=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/ttyskeepawake/{print $2; exit}' || echo "?")
    local current="acwake=${_aw} lidwake=${_lw} ttyskeepawake=${_tty}" default="acwake=0 lidwake=1 ttyskeepawake=1" optimized="acwake=1 lidwake=1 ttyskeepawake=1"
    _run_item "$num" "power_clamshell" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo pmset -c acwake 0; sudo pmset -c lidwake 1; sudo pmset -c ttyskeepawake 1
        ok "Clamshell reset to macOS default (acwake=0)"
    else
        sudo pmset -c acwake 1; sudo pmset -c lidwake 1; sudo pmset -c ttyskeepawake 1
        ok "Clamshell mode enabled (AC)"
    fi
}

apply_power_nap_ac() {
    local num="$1" desc="$2"
    local current default="1 (on)" optimized="0 (off)"
    current=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/powernap/{print $2; exit}' || echo "?")
    _run_item "$num" "power_nap_ac" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    [ "$_rc" -eq 2 ] && sudo pmset -c powernap 1 || sudo pmset -c powernap 0
    ok "AC powernap = $( [ "$_rc" -eq 2 ] && echo 1 || echo 0 )"
}

apply_power_disk_sleep_ac() {
    local num="$1" desc="$2"
    local current default="10 min" optimized="10 min"
    current=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/disksleep/{print $2; exit}' || echo "?")
    _run_item "$num" "power_disk_sleep_ac" "$desc" "${current} min" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo pmset -c disksleep 10
    ok "AC disksleep = 10"
}

apply_power_display_sleep_bat() {
    local num="$1" desc="$2"
    local current default="2 min" optimized="2 min"
    current=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/displaysleep/{print $2; exit}' || echo "?")
    _run_item "$num" "power_display_sleep_bat" "$desc" "${current} min" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b displaysleep 2
    ok "Battery displaysleep = 2"
}

apply_power_system_sleep_bat() {
    local num="$1" desc="$2"
    local current default="5 min" optimized="5 min"
    current=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/^[ ]+sleep /{print $2; exit}' || echo "?")
    _run_item "$num" "power_system_sleep_bat" "$desc" "${current} min" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b sleep 5
    ok "Battery sleep = 5"
}

apply_power_standby_bat() {
    local num="$1" desc="$2"
    local current default="1 (on)" optimized="0 (off)"
    current=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/standby/{print $2; exit}' || echo "?")
    _run_item "$num" "power_standby_bat" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    [ "$_rc" -eq 2 ] && sudo pmset -b standby 1 || sudo pmset -b standby 0
    ok "Battery standby = $( [ "$_rc" -eq 2 ] && echo 1 || echo 0 )"
}

apply_power_nap_bat() {
    local num="$1" desc="$2"
    local current default="0 (off)" optimized="0 (off)"
    current=$(pmset -g custom 2>/dev/null | awk '/Battery Power/,/AC Power/' | awk '/powernap/{print $2; exit}' || echo "?")
    _run_item "$num" "power_nap_bat" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo pmset -b powernap 0
    ok "Battery powernap = 0"
}

apply_hibernate_mode_ac() {
    local num="$1" desc="$2"
    local current default="3 (safe sleep — RAM + disk image)" optimized="0 (RAM-only sleep, no disk write)"
    current=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/hibernatemode/{print $2; exit}' || echo "?")
    _run_item "$num" "hibernate_mode_ac" "$desc" "hibernatemode=${current}" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo pmset -c hibernatemode 3
        ok "AC hibernatemode reset to macOS default (3 — safe sleep)"
    else
        sudo pmset -c hibernatemode 0
        ok "AC hibernatemode = 0 (RAM-only sleep; no sleep image written to SSD)"
    fi
}

apply_wol_ac() {
    local num="$1" desc="$2"
    local current default="1 (Wake on LAN enabled)" optimized="0 (Wake on LAN disabled)"
    current=$(pmset -g custom 2>/dev/null | awk '/AC Power/,0' | awk '/^[ ]*womp/{print $2; exit}' || echo "?")
    _run_item "$num" "wol_ac" "$desc" "womp=${current}" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo pmset -c womp 1
        ok "Wake on LAN reset to macOS default (enabled)"
    else
        sudo pmset -c womp 0
        ok "Wake on LAN disabled (womp=0)"
    fi
}

# ── NETWORK ────────────────────────────────────────────────────────────────

apply_tcp_socket_buffer() {
    local num="$1" desc="$2"
    local current default="4194304 (4 MB)" optimized="16777216 (16 MB)"
    current=$(sysctl -n kern.ipc.maxsockbuf 2>/dev/null || echo "?")
    _run_item "$num" "tcp_socket_buffer" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    [ "$_rc" -eq 2 ] && sudo sysctl -w kern.ipc.maxsockbuf=4194304 \
                     || sudo sysctl -w kern.ipc.maxsockbuf=16777216
    ok "kern.ipc.maxsockbuf = $( [ "$_rc" -eq 2 ] && echo 4194304 || echo 16777216 )"
}

apply_tcp_send_recv_space() {
    local num="$1" desc="$2"
    local _send _recv
    _send=$(sysctl -n net.inet.tcp.sendspace 2>/dev/null || echo "?")
    _recv=$(sysctl -n net.inet.tcp.recvspace 2>/dev/null || echo "?")
    local current="send=${_send} recv=${_recv}" default="send=131072 recv=131072 (128 KB)" optimized="send=1048576 recv=1048576 (1 MB)"
    _run_item "$num" "tcp_send_recv_space" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo sysctl -w net.inet.tcp.sendspace=131072
        sudo sysctl -w net.inet.tcp.recvspace=131072
    else
        sudo sysctl -w net.inet.tcp.sendspace=1048576
        sudo sysctl -w net.inet.tcp.recvspace=1048576
    fi
    ok "TCP send/recv space set"
}

apply_tcp_somaxconn() {
    local num="$1" desc="$2"
    local current default="128" optimized="2048"
    current=$(sysctl -n kern.ipc.somaxconn 2>/dev/null || echo "?")
    _run_item "$num" "tcp_somaxconn" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    [ "$_rc" -eq 2 ] && sudo sysctl -w kern.ipc.somaxconn=128 \
                     || sudo sysctl -w kern.ipc.somaxconn=2048
    ok "kern.ipc.somaxconn = $( [ "$_rc" -eq 2 ] && echo 128 || echo 2048 )"
}

apply_sysctl_perf() {
    local num="$1" desc="$2"
    local current default="~263168 (OS default)" optimized="750000"
    current=$(sysctl -n kern.maxvnodes 2>/dev/null || echo "?")
    _run_item "$num" "sysctl_perf" "$desc" "maxvnodes=${current}" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo sysctl -w kern.maxvnodes=263168
        ok "kern.maxvnodes reset to macOS default (263168)"
    else
        sudo sysctl -w kern.maxvnodes=750000
        ok "kern.maxvnodes = 750000"
    fi
}

apply_iogpu_wired_limit() {
    local num="$1" desc="$2"
    local _mem_mb _optimized_mb
    _mem_mb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
    _optimized_mb=$(( _mem_mb - 6144 ))
    local current default="0 (fully dynamic, no cap)" optimized="${_optimized_mb} MB (RAM − 6 GB)"
    current=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo "?")
    _run_item "$num" "iogpu_wired_limit" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo sysctl -w iogpu.wired_limit_mb=0
        ok "iogpu.wired_limit_mb = 0 (fully dynamic)"
    else
        sudo sysctl -w iogpu.wired_limit_mb="${_optimized_mb}"
        ok "iogpu.wired_limit_mb = ${_optimized_mb} MB (${_mem_mb} MB RAM − 6144 MB)"
    fi
}

apply_sysctl_persist() {
    local num="$1" desc="$2"
    local current default="(file absent)" optimized="/etc/sysctl.conf written"
    [ -f /etc/sysctl.conf ] && current="exists ($(wc -l < /etc/sysctl.conf | tr -d ' ') lines)" || current="does not exist"
    _run_item "$num" "sysctl_persist" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo rm -f /etc/sysctl.conf
        ok "/etc/sysctl.conf removed (macOS default: absent)"
    else
        # iogpu.wired_limit_mb is RAM-dependent so must be computed at write-time
        local _mem_mb _iogpu_limit
        _mem_mb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
        _iogpu_limit=$(( _mem_mb - 6144 ))
        sudo tee /etc/sysctl.conf > /dev/null << SCTLEOF
# sysctl.conf — managed by optimizations.sh
# Rollback: delete this file and reboot
# Note: kern.maxproc/maxfiles/maxfilesperproc intentionally omitted —
#       macOS ships with higher values already (16000/491520/245760).
#       kern.ipc.nmbclusters is read-only on this platform.
#       net.inet.tcp.delayed_ack removed — net loss on Wi-Fi-only machine.

kern.ipc.maxsockbuf=16777216
net.inet.tcp.sendspace=1048576
net.inet.tcp.recvspace=1048576
kern.ipc.somaxconn=2048
net.inet.tcp.mssdflt=1440
net.inet.tcp.blackhole=2
kern.maxvnodes=750000
iogpu.wired_limit_mb=${_iogpu_limit}
SCTLEOF
        ok "/etc/sysctl.conf written (iogpu.wired_limit_mb=${_iogpu_limit})"
    fi
}

apply_dns_flush() {
    local num="$1" desc="$2"
    local current="(live DNS cache)" default="(flush)" optimized="(flush)"
    _run_item "$num" "dns_flush" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    sudo dscacheutil -flushcache
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    ok "DNS cache flushed"
}

# ── UPDATES ────────────────────────────────────────────────────────────────

apply_apple_autoupdate() {
    local num="$1" desc="$2"
    local current default="true (auto-check enabled)" optimized="false (all auto-update disabled)"
    current=$(dfw read com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null || echo "(not set)")
    _run_item "$num" "apple_autoupdate" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.commerce AutoUpdate -bool true
        dfw write com.apple.SoftwareUpdate AutomaticDownload -bool true
        dfw write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool true
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool true
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool true
        ok "Apple Software Update reset to macOS default (enabled)"
    else
        dfw write com.apple.commerce AutoUpdate -bool false
        dfw write com.apple.SoftwareUpdate AutomaticDownload -bool false
        dfw write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool false
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false
        sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
        ok "Apple Software Update disabled (user + system domain)"
    fi
}

apply_airdrop() {
    local num="$1" desc="$2"
    local current default="false (AirDrop on)" optimized="true (AirDrop off)"
    current=$(dfw read com.apple.NetworkBrowser DisableAirDrop 2>/dev/null || echo "(not set)")
    _run_item "$num" "airdrop" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        dfw write com.apple.NetworkBrowser DisableAirDrop -bool false
        ok "AirDrop re-enabled (macOS default)"
    else
        dfw write com.apple.NetworkBrowser DisableAirDrop -bool true
        ok "AirDrop disabled"
    fi
}

apply_handoff_continuity() {
    local num="$1" desc="$2"
    local current default="true (Handoff on)" optimized="false (Handoff off)"
    current=$(dfw -currentHost read com.apple.coreservices.useractivityd ActivityReceivingAllowed 2>/dev/null || echo "(not set)")
    _run_item "$num" "handoff_continuity" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=true || _val=false
    dfw -currentHost write com.apple.coreservices.useractivityd ActivityReceivingAllowed -bool "$_val"
    dfw -currentHost write com.apple.coreservices.useractivityd ActivityAdvertisingAllowed -bool "$_val"
    ok "Handoff/Continuity set to ${_val}"
}

# ── SECURITY ───────────────────────────────────────────────────────────────

apply_smb_guest() {
    local num="$1" desc="$2"
    local SMB_PLIST="/Library/Preferences/SystemConfiguration/com.apple.smb.server"
    local current default="true (guest allowed)" optimized="false (auth required)"
    current=$(defaults read "$SMB_PLIST" AllowGuestAccess 2>/dev/null || echo "(not set)")
    _run_item "$num" "smb_guest" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _val; [ "$_rc" -eq 2 ] && _val=true || _val=false
    sudo defaults write "$SMB_PLIST" AllowGuestAccess -bool "$_val"
    ok "SMB AllowGuestAccess = ${_val}"
}

apply_ssh_server() {
    local num="$1" desc="$2"
    local current default="Off" optimized="Off"
    current=$(sudo systemsetup -getremotelogin 2>/dev/null | awk '{print $NF}' || echo "?")
    _run_item "$num" "ssh_server" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _ssh_err
    if [ "$_rc" -eq 2 ]; then
        # macOS default is Off — same as optimized; re-enable if user wants
        _ssh_err=$(echo "yes" | sudo systemsetup -setremotelogin on 2>&1)
        [ $? -eq 0 ] && ok "SSH server enabled" || warn "Could not enable SSH server: $_ssh_err"
    else
        _ssh_err=$(echo "yes" | sudo systemsetup -setremotelogin off 2>&1)
        [ $? -eq 0 ] && ok "SSH server disabled" || warn "Could not disable SSH server: $_ssh_err"
    fi
}

apply_remote_apple_events() {
    local num="$1" desc="$2"
    local current default="Off" optimized="Off"
    current=$(sudo systemsetup -getremoteappleevents 2>/dev/null | awk '{print $NF}' || echo "?")
    _run_item "$num" "remote_apple_events" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$current" = "Off" ] && [ "$_rc" -ne 2 ]; then
        ok "Remote Apple Events already off — skipping setter"
        return 0
    fi
    local _rae_err
    if [ "$_rc" -eq 2 ]; then
        _rae_err=$(sudo systemsetup -setremoteappleevents on 2>&1)
        [ $? -eq 0 ] && ok "Remote Apple Events enabled" || warn "Could not enable: $_rae_err"
    else
        _rae_err=$(sudo systemsetup -setremoteappleevents off 2>&1)
        [ $? -eq 0 ] && ok "Remote Apple Events disabled" || warn "Could not disable: $_rae_err"
    fi
}

apply_gatekeeper() {
    local num="$1" desc="$2"
    local current default="assessments enabled" optimized="assessments disabled"
    current=$(spctl --status 2>/dev/null | head -1 || echo "?")
    _run_item "$num" "gatekeeper" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _gk_err
    if [ "$_rc" -eq 2 ]; then
        _gk_err=$(sudo spctl --master-enable 2>&1)
        [ $? -eq 0 ] && ok "Gatekeeper re-enabled" || warn "Could not enable Gatekeeper: $_gk_err"
    else
        _gk_err=$(sudo spctl --master-disable 2>&1)
        [ $? -eq 0 ] && ok "Gatekeeper disabled" || warn "Could not disable Gatekeeper: $_gk_err"
    fi
}

apply_mdns_multicast() {
    local num="$1" desc="$2"
    local MDNS_PLIST="/Library/Preferences/com.apple.mDNSResponder.plist"
    local current default="false (mDNS advertising active)" optimized="true (multicast suppressed)"
    current=$(sudo defaults read "$MDNS_PLIST" NoMulticastAdvertisements 2>/dev/null || echo "(not set)")
    _run_item "$num" "mdns_multicast" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        sudo defaults write "$MDNS_PLIST" NoMulticastAdvertisements -bool false
    else
        sudo defaults write "$MDNS_PLIST" NoMulticastAdvertisements -bool true
    fi
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    ok "mDNS NoMulticastAdvertisements = $( [ "$_rc" -eq 2 ] && echo false || echo true )"
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
    local current="${already}/${#TELEMETRY_HOSTS[@]} already blocked" default="none blocked" optimized="all 11 blocked in /etc/hosts"
    _run_item "$num" "hosts_telemetry" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    if [ "$_rc" -eq 2 ]; then
        for h in "${TELEMETRY_HOSTS[@]}"; do
            sudo sed -i.bak "/0\.0\.0\.0 ${h}/d" /etc/hosts 2>/dev/null || true
        done
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        ok "Telemetry entries removed from /etc/hosts"
    else
        local added=0
        for h in "${TELEMETRY_HOSTS[@]}"; do
            if ! grep -qF "$h" /etc/hosts 2>/dev/null; then
                echo "0.0.0.0 $h" | sudo tee -a /etc/hosts > /dev/null
                added=$((added+1))
            fi
        done
        sudo killall -HUP mDNSResponder 2>/dev/null || true
        ok "Added $added telemetry entries to /etc/hosts"
    fi
}

apply_alf_firewall() {
    local num="$1" desc="$2"
    local FW="/usr/libexec/ApplicationFirewall/socketfilterfw"
    local current default="disabled" optimized="enabled + stealth mode on"
    current=$("$FW" --getglobalstate 2>/dev/null | head -1 || echo "?")
    _run_item "$num" "alf_firewall" "$desc" "$current" "$default" "$optimized"
    local _rc=$?; [ "$_rc" -eq 1 ] && return 0; [ "$DRY_RUN" = true ] && return 0
    local _fw_ok=true _fw_err
    if [ "$_rc" -eq 2 ]; then
        _fw_err=$(sudo "$FW" --setglobalstate off 2>&1) || { warn "Firewall off: $_fw_err"; _fw_ok=false; }
        [ "$_fw_ok" = true ] && ok "ALF firewall disabled (macOS default)"
    else
        _fw_err=$(sudo "$FW" --setglobalstate on 2>&1)  || { warn "Firewall on: $_fw_err"; _fw_ok=false; }
        _fw_err=$(sudo "$FW" --setstealthmode on 2>&1)   || { warn "Stealth on: $_fw_err"; _fw_ok=false; }
        _fw_err=$(sudo "$FW" --setallowsigned on 2>&1)   || { warn "Allowsigned on: $_fw_err"; _fw_ok=false; }
        _fw_err=$(sudo "$FW" --setblockall off 2>&1)      || { warn "Blockall off: $_fw_err"; _fw_ok=false; }
        [ "$_fw_ok" = true ] && ok "ALF firewall enabled with stealth mode" \
                             || warn "ALF firewall partially configured — check warnings above"
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
