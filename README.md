# Machete aka Mac-hete

A macOS debloating and tuning toolkit for Apple Silicon, targeting macOS 26.x (Sequoia/Tahoe).

Removes unwanted system binaries from the Sealed System Volume (SSV), disables background agents and daemons, applies 109 confirmed system-preference optimizations, and bundles a memory/CPU/GPU benchmark suite to measure before-and-after impact.

---

> [!WARNING]
> **This toolkit makes irreversible changes to macOS internals.**
>
> - Requires **SIP disabled** and **authenticated-root disabled** (Recovery-only operations)
> - Modifies the **Sealed System Volume** — macOS software updates **will no longer work** after running `debloat.sh`
> - A failed or incomplete run can leave the system **unbootable**
> - A restore snapshot is automatically created before any changes; keep the `restore.sh` script accessible from your external drive
> - **Do not run on a machine you are not prepared to reinstall**

---

## Components

| Script | Purpose |
|--------|---------|
| `debloat.sh` | Main executor: removes SSV binaries, disables agents/daemons, cleans user data |
| `manifest.yaml` | Declarative feature manifest: ~40 features with apps, frameworks, agents, daemons, plists, user containers |
| `optimize.sh` | 109 `defaults write` / `sysctl` / `pmset` optimizations across 11 groups |
| `cleanup.sh` | Post-debloat cleanup: Spotlight, LaunchServices, CoreSpotlight, icon cache |
| `restore.sh` | Recovery Terminal script: lists snapshots, auto-detects volumes, restores boot target |
| `uninstall.sh` | Removes all user-installed software: apps, Homebrew, pip, npm, kexts, agents |
| `membench/` | Benchmark suite: memory bandwidth, CPU compute, cache hierarchy, GPU memory, storage, inter-core |

---

## Prerequisites

Before running any script that modifies the SSV (`debloat.sh`):

1. **Boot to Recovery** — hold power until "Loading startup options" appears → Options → Continue
2. Open **Utilities → Terminal**
3. Disable SIP:
   ```
   csrutil disable
   ```
4. Disable authenticated-root:
   ```
   csrutil authenticated-root disable
   ```
5. **Reboot** back to normal macOS
6. Run scripts from the **live system** (except `restore.sh`, which runs from Recovery)

`optimize.sh` and `uninstall.sh` do **not** require SIP/authenticated-root to be disabled and can be run on a stock system.

---

## Quick Start

### Preview everything (no changes made)
```bash
sudo ./debloat.sh --dry-run
sudo ./optimize.sh --dry-run
```

### Debloat specific features
```bash
# Preview
sudo ./debloat.sh --dry-run --features siri,maps,news

# Apply (creates restore snapshot, confirms each feature interactively)
sudo ./debloat.sh --features siri,maps,news

# Apply all features, skip confirmation prompts
sudo ./debloat.sh --yes
```

### Apply optimizations
```bash
# List all 109 keys grouped by category
./optimize.sh --list

# Preview all
./optimize.sh --dry-run

# Apply a single group interactively
sudo ./optimize.sh --group trackpad

# Apply specific items non-interactively
sudo ./optimize.sh --yes --item touchid_sudo,key_repeat_rate

# Skip personal settings
sudo ./optimize.sh --yes --skip timezone,computer_name,dock_strip,wallpaper_black
```

### Post-debloat cleanup
Runs automatically as Phase G of `debloat.sh`. Can also be run standalone:
```bash
sudo ./cleanup.sh --features siri,maps,news
```

---

## Customization

`optimize.sh` contains a **USER CONFIGURATION** block near the top of the file with variables for personal preferences. Edit these before running:

```bash
MACHETE_TIMEZONE="Australia/Perth"    # e.g. "America/New_York", "Europe/London"
MACHETE_COMPUTER_NAME="M5"            # ComputerName, LocalHostName, HostName
MACHETE_DOCK_APPS=(                   # Apps to pin in the Dock (applied by dock_strip)
    "/System/Applications/Utilities/Terminal.app"
    "/System/Applications/System Settings.app"
)
```

To skip these entirely:
```bash
sudo ./optimize.sh --skip timezone,computer_name,dock_strip
```

---

## Debloatable Features

List all features defined in `manifest.yaml`:
```bash
sudo ./debloat.sh --list
```

Each feature entry in the manifest contains:
- **SSV paths** — binaries and frameworks to delete from the sealed volume
- **Agents** — LaunchAgent labels to disable via `launchctl`
- **Daemons** — LaunchDaemon labels to disable via `launchctl`
- **PluginKit** — extension bundle IDs to suppress via `pluginkit -e ignore`
- **User data** — containers, group containers, preferences, caches to remove

Features include: `siri`, `maps`, `news`, `stocks`, `weather`, `translate`, `freeform`, `shortcuts`, `screen_time`, `icloud`, `facetime`, `messages_continuation`, `spotlight_suggestions`, `memoji_avatars`, `game_center`, `podcasts`, `music`, `tv_streaming`, `apple_arcade`, `notes_collaboration`, `reminders`, `calendar`, `contacts`, `photos_sharing`, `home`, `wallet`, `apple_pay`, `health`, `fitness`, `screen_saver`, `dictation`, `continuity_camera`, `handoff`, `follow_up`, `misc_daemons`, and more.

> [!CAUTION]
> Removing the wrong feature can break core macOS functionality.
> Always run with `--dry-run` first and review the output carefully.
> The `--verify` flag runs a read-only dependency audit using `otool -L`, `kextstat`, `plutil`, and `pluginkit` before any changes.

---

## Optimizations

Run `./optimize.sh --list` for the full annotated list. Groups:

| Group | Items | Examples |
|-------|-------|---------|
| `input` | 4 | Key repeat fastest, press-and-hold off, Touch ID sudo |
| `trackpad` | 8 | Max speed, tap-to-click, tap-to-drag, natural scroll off |
| `spotlight` | 6 | Boot-volume-only indexing, Apps+Calculator+Settings categories |
| `animations` | 7 | All window/scroll/motion animations disabled |
| `dock` | 12 | Auto-hide instant, no bounce, minimize into icon, hot corners off |
| `finder` | 26 | Hidden files, path bar, list view, no iCloud, DS_Store cleanup |
| `ui` | 13 | Maximize on green button, no widgets, ISO 8601 clock, black wallpaper |
| `power` | 10 | AC/battery sleep timers, Power Nap off, clamshell mode |
| `network` | 7 | 16 MB socket buffer, 1 MB TCP send/recv, sysctl persist |
| `updates` | 6 | Apple SU off, Chrome Keystone off, Edge updater off, AirDrop off |
| `security` | 8 | ALF firewall+stealth, Gatekeeper off, pfctl telemetry block |

---

## Recovery

If the system fails to boot after debloating, use `restore.sh` from Recovery Terminal:

```bash
# In Recovery Terminal (hold power → Options → Recovery → Utilities → Terminal)
chmod +x /Volumes/<your-drive>/Machete/restore.sh
/Volumes/<your-drive>/Machete/restore.sh
```

The script auto-detects volume layout, lists available snapshots (pre-debloat restore point + Apple stock snapshot), and runs `bless --setBoot --snapshot` to set your chosen snapshot as the boot target.

Manual recovery (if the script is unavailable):
```bash
# 1. Mount Preboot (required by bless)
mount_apfs -o nobrowse /dev/diskXsY /System/Volumes/Preboot

# 2. Mount System volume
mount_apfs -o nobrowse /dev/diskAsB /System/Volumes/Update/mnt1

# 3. Set boot snapshot (UUID from debloat.sh output or RESTORE-CMD.txt)
bless --mount /System/Volumes/Update/mnt1 --setBoot --snapshot <UUID>

reboot
```

The restore snapshot UUID is also written to `debloat-<timestamp>-RESTORE-CMD.txt` alongside the log file.

---

## Membench

A benchmark suite for Apple Silicon to measure the impact of debloating on available memory and performance.

```bash
cd membench/code

# Build (requires Xcode Command Line Tools)
./build.sh

# Run all benchmarks
./run.sh
```

Benchmarks: memory bandwidth (sequential read/write), CPU compute (FLOPS), cache hierarchy (L1/L2/L3/RAM latency), inter-core latency, storage throughput, GPU memory bandwidth (Metal).

---

## Architecture

### debloat.sh phases

| Phase | Name | Description |
|-------|------|-------------|
| A | Pre-mount | Parse manifest, resolve device nodes, build SSV deletion list, create restore snapshot |
| B | SSV mount | **< 60s window** — mount SSV R/W, `rm -rf` all paths, patch plists, `bless --create-snapshot` |
| C | Post-mount | Verify new boot snapshot, clean stale bless snapshots |
| D | Live | `launchctl disable` all feature agents and daemons, bootout running instances |
| E | PluginKit | `pluginkit -e ignore` all feature extension bundle IDs |
| F | User data | Remove per-user containers, group containers, preferences, caches |
| G | Cleanup | Invoke `cleanup.sh` for Spotlight, LaunchServices, icon cache |

### manifest.yaml structure

```yaml
feature_name:
  description: Human-readable description
  apps: []          # /Applications/*.app paths
  helpers: []       # Helper/XPC app paths within frameworks
  frameworks: []    # System/Library/Frameworks and PrivateFrameworks
  appex: []         # Extension bundle names
  agents: []        # LaunchAgent labels (without com.apple. prefix)
  daemons: []       # LaunchDaemon labels
  pluginkit: []     # Extension bundle IDs for pluginkit suppress
  user_containers: []
  user_group_containers: []
  user_prefs: []
  user_caches: []
```

---

## License

[MIT](LICENSE)
