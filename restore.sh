#!/bin/bash
# ==============================================================================
# DEBLOAT RESTORE SCRIPT
# MUST be run from Recovery Terminal — not from the live booted system.
#
# USAGE (from Recovery Terminal — replace <your-drive> with your external drive name):
#   chmod +x /Volumes/<your-drive>/Machete/restore.sh
#   /Volumes/<your-drive>/Machete/restore.sh
#
# Or jump straight to a specific snapshot:
#   /Volumes/<your-drive>/Machete/restore.sh <snapshot-uuid>
#
# HOW TO GET TO RECOVERY TERMINAL:
#   1. Hold power button until "Loading startup options" appears
#   2. Click Options → Continue
#   3. Select a user and enter password
#   4. Menu bar → Utilities → Terminal
#   5. Run this script
#
# WHAT THIS DOES:
#   1. Detects the correct system/preboot volume devices from diskutil
#   2. Mounts the Preboot volume — bless needs this to write boot metadata
#   3. Mounts the System volume (SSV) — requires Recovery, not live macOS
#   4. Runs bless --setBoot --snapshot to set the chosen snapshot as boot target
#   5. Reboots
# ==============================================================================

set -uo pipefail

# ── Resolve own path (for self-referencing in messages) ───────────────────────
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
ok()   { echo "${GREEN}  OK   $*${RESET}"; }
warn() { echo "${YELLOW}  WARN $*${RESET}"; }
err()  { echo "${RED}  ERR  $*${RESET}"; }
log()  { echo "  ...  $*"; }
die()  { err "$*"; exit 1; }

echo ""
echo "============================================================"
echo "  DEBLOAT RESTORE SCRIPT"
echo "============================================================"
echo ""

# ── Guard: must be root ───────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    die "Must be run as root. In Recovery Terminal, commands run as root automatically."
fi

# ── Auto-detect volume devices from diskutil ──────────────────────────────────
# Cannot use "/" to find the system volume — in Recovery, "/" is the recovery
# ramdisk (e.g. disk5s1), NOT the main system volume.
# Use APFS role (System) instead of hardcoded volume names.
log "Detecting volume layout..."

# Primary: find the volume with APFS role "(System)" — works regardless of volume name
SYSTEM_ID=$(diskutil apfs list 2>/dev/null \
    | awk '/APFS Volume Disk.*Role.*System/{
        for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]/) {print $i; exit}
    }')
if [ -z "$SYSTEM_ID" ]; then
    # Fallback: search diskutil list for a non-Data volume in the largest APFS container
    # (handles edge cases where diskutil apfs list isn't available)
    SYSTEM_ID=$(diskutil list 2>/dev/null \
        | awk '/APFS Volume [^-]/{id=$NF} /APFS Snapshot/{print id; exit}')
fi
if [ -z "$SYSTEM_ID" ]; then
    err "Could not find the system volume (APFS role 'System')."
    err "Run 'diskutil apfs list' and identify the system volume identifier,"
    err "then re-run with manual bless:"
    err "  diskutil mount <identifier>"
    err "  bless --mount <mount_path> --setBoot --snapshot <uuid>"
    err ""
    err "Current disk layout:"
    diskutil list 2>&1 | sed 's/^/  /'
    exit 1
fi
SYSTEM_DEV="/dev/$SYSTEM_ID"

# Container: disk3s1 → disk3
CONTAINER=$(echo "$SYSTEM_ID" | sed 's/s[0-9]*$//')

log "  System volume:  $SYSTEM_DEV"
log "  APFS container: $CONTAINER"

# Find Preboot volume in the same container
PREBOOT_DEV=$(diskutil list "$CONTAINER" 2>/dev/null | awk '/Preboot/{print "/dev/"$NF; exit}')
if [ -z "$PREBOOT_DEV" ]; then
    PREBOOT_DEV=$(diskutil list 2>/dev/null | awk '/Preboot/{print "/dev/"$NF; exit}')
fi
log "  Preboot volume: ${PREBOOT_DEV:-(not found)}"

PREBOOT_MOUNT="/System/Volumes/Preboot"

# ── List available snapshots ──────────────────────────────────────────────────
# Try the system volume directly first (works when it's mounted).
# If that fails, try via any snapshot device (disk3s1s1).
log "Scanning available snapshots on $SYSTEM_DEV..."
SNAP_LIST=$(diskutil apfs listSnapshots "$SYSTEM_ID" 2>/dev/null || true)
if [ -z "$SNAP_LIST" ] || echo "$SNAP_LIST" | grep -q "Error"; then
    # Volume not mounted yet — try the snapshot slice (e.g. disk3s1s1)
    SNAP_SLICE=$(diskutil list "$CONTAINER" 2>/dev/null \
        | awk '/APFS Snapshot/{print $NF; exit}')
    if [ -n "$SNAP_SLICE" ]; then
        log "  (querying via snapshot device $SNAP_SLICE)"
        SNAP_LIST=$(diskutil apfs listSnapshots "$SNAP_SLICE" 2>/dev/null || true)
    fi
fi

if [ -z "$SNAP_LIST" ]; then
    warn "Could not list snapshots. Will proceed with manual UUID entry."
fi

# Parse: extract UUID + Name + XID
# diskutil output: "+-- <UUID>" then "Name: <name>" then "XID: <num>"
SNAP_UUIDS=()
SNAP_NAMES=()
SNAP_XIDS=()
_cur_xid=""
while IFS= read -r line; do
    if [[ "$line" =~ ^\+--[[:space:]]([0-9A-F-]{36}) ]]; then
        SNAP_UUIDS+=("${BASH_REMATCH[1]}")
        SNAP_NAMES+=("")
        SNAP_XIDS+=("")
        _cur_xid=""
    elif [[ "$line" =~ Name:[[:space:]]+(.+) ]] && [ ${#SNAP_UUIDS[@]} -gt 0 ]; then
        SNAP_NAMES[${#SNAP_NAMES[@]}-1]="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ XID:[[:space:]]+([0-9]+) ]] && [ ${#SNAP_UUIDS[@]} -gt 0 ]; then
        SNAP_XIDS[${#SNAP_XIDS[@]}-1]="${BASH_REMATCH[1]}"
    fi
done <<< "$SNAP_LIST"

# ── Load snapshot metadata (written by debloat.sh) ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP_META="$SCRIPT_DIR/snapshot-metadata.tsv"

# _meta_lookup UUID field_num → returns the field (1=uuid 2=date 3=type 4=features 5=macos_version)

# ── Seed metadata TSV from live diskutil data (fallback for pre-existing snaps) ─
# For every snapshot visible to diskutil that is not yet in the TSV, adds a
# best-effort row derived from the snapshot name so restore.sh always has
# something to display. Rows written by debloat.sh (with real timestamps and
# feature lists) are never overwritten — the grep guard makes this idempotent.
_seed_snap_meta() {
    # Create file with header if missing
    if [ ! -f "$SNAP_META" ]; then
        printf 'uuid\tdate\ttype\tfeatures\tmacos_version\n' > "$SNAP_META"
    fi
    local i uuid name _type _features
    for i in "${!SNAP_UUIDS[@]}"; do
        uuid="${SNAP_UUIDS[$i]}"
        name="${SNAP_NAMES[$i]}"
        [ -z "$uuid" ] && continue
        # Skip if already recorded (debloat.sh wrote a real row)
        grep -qF "$uuid" "$SNAP_META" 2>/dev/null && continue
        # Derive type + features from snapshot name
        if echo "$name" | grep -q "os\.update"; then
            _type="os-update"
            _features="(stock macOS — original install)"
        elif echo "$name" | grep -q "debloat\.restore"; then
            _type="restore"
            _features="(pre-debloat state — metadata predates recording)"
        elif echo "$name" | grep -q "bless"; then
            _type="boot"
            _features="(debloat boot snapshot — metadata predates recording)"
        else
            _type="unknown"
            _features="${name:-(no name)}"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$uuid" "(unknown)" "$_type" "$_features" "(unknown)" >> "$SNAP_META"
    done
}
[ ${#SNAP_UUIDS[@]} -gt 0 ] && _seed_snap_meta

# _meta_lookup UUID field_num → returns the field value from the TSV
_meta_lookup() {
    local uuid="$1" field="$2"
    [ -f "$SNAP_META" ] || return
    awk -F'\t' -v u="$uuid" -v f="$field" '$1 == u {print $f; exit}' "$SNAP_META"
}

# ── Accept optional UUID override from command-line ───────────────────────────
TARGET_UUID=""
if [ $# -ge 1 ]; then
    TARGET_UUID="$1"
    log "Using command-line UUID: $TARGET_UUID"
fi

# ── Prompt for snapshot choice ────────────────────────────────────────────────
if [ -z "$TARGET_UUID" ]; then
    echo ""
    echo "  Available snapshots on $SYSTEM_DEV (oldest first):"
    echo ""
    if [ ${#SNAP_UUIDS[@]} -eq 0 ]; then
        warn "  No snapshots found. You may need to enter a UUID manually."
        echo ""
    else
        for i in "${!SNAP_UUIDS[@]}"; do
            local_num=$((i + 1))
            local_name="${SNAP_NAMES[$i]}"
            local_uuid="${SNAP_UUIDS[$i]}"
            local_xid="${SNAP_XIDS[$i]}"

            # Classify snapshot type
            local_type=""
            local_boot=""
            if echo "$local_name" | grep -q "os.update"; then
                local_type="stock macOS (original install)"
            elif echo "$local_name" | grep -q "debloat.restore"; then
                local_type="pre-debloat restore point"
            elif echo "$local_name" | grep -q "bless"; then
                local_type="debloat boot snapshot"
            else
                local_type="$local_name"
            fi

            # Check if this is the current boot snapshot
            if echo "$SNAP_LIST" | grep -A3 "$local_uuid" | grep -q "Will root to"; then
                local_boot="  ← CURRENT BOOT"
            fi

            # Look up metadata from debloat.sh's snapshot-metadata.tsv
            local_meta_date=$(_meta_lookup "$local_uuid" 2)
            local_meta_type=$(_meta_lookup "$local_uuid" 3)
            local_meta_feats=$(_meta_lookup "$local_uuid" 4)

            # Override type with metadata if available
            if [ -n "$local_meta_type" ]; then
                case "$local_meta_type" in
                    restore) local_type="pre-debloat restore point" ;;
                    boot)    local_type="debloat boot snapshot" ;;
                esac
            fi

            printf "  [%d] %s%s\n" "$local_num" "$local_type" "$local_boot"
            printf "      UUID: %s   XID: %s\n" "$local_uuid" "${local_xid:--}"
            [ -n "$local_meta_date" ]  && printf "      Date: %s\n" "$local_meta_date"
            [ -n "$local_meta_feats" ] && printf "      Features: %s\n" "$local_meta_feats"
            echo ""
        done
    fi
    printf "  [m] Enter UUID manually\n\n"
    printf "  Choice: "
    read -r CHOICE < /dev/tty
    echo ""

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#SNAP_UUIDS[@]}" ]; then
        TARGET_UUID="${SNAP_UUIDS[$((CHOICE - 1))]}"
    elif [ "$CHOICE" = "m" ] || [ "$CHOICE" = "M" ] || [ ${#SNAP_UUIDS[@]} -eq 0 ]; then
        printf "  Enter UUID: "
        read -r TARGET_UUID < /dev/tty
    else
        die "Invalid choice: $CHOICE"
    fi
fi

[ -z "$TARGET_UUID" ] && die "No UUID provided."

echo ""
log "Target snapshot: $TARGET_UUID"
echo ""

# ── Step 1: Mount Preboot volume ──────────────────────────────────────────────
echo "------------------------------------------------------------"
echo "  Step 1: Mount Preboot volume ($PREBOOT_DEV)"
echo "------------------------------------------------------------"

if [ -z "$PREBOOT_DEV" ]; then
    warn "Preboot device not detected — skipping. bless may fail."
else
    mkdir -p "$PREBOOT_MOUNT" 2>/dev/null || true

    if mount | awk '{print $3}' | grep -qF "$PREBOOT_MOUNT"; then
        ok "Preboot already mounted at $PREBOOT_MOUNT"
    else
        _PMOUNT_ERR=$(mount_apfs -o nobrowse "$PREBOOT_DEV" "$PREBOOT_MOUNT" 2>&1)
        _PMOUNT_RET=$?
        if [ $_PMOUNT_RET -eq 0 ]; then
            ok "Preboot mounted at $PREBOOT_MOUNT"
        else
            # exit 16 = EBUSY = already mounted under a different path — check
            if mount | grep -q "$PREBOOT_DEV"; then
                ok "Preboot ($PREBOOT_DEV) already mounted (different path)"
            else
                warn "Could not mount Preboot: $_PMOUNT_ERR"
                warn "bless may fail. Continuing..."
            fi
        fi
    fi
fi

# ── Step 2: Mount System volume writable ─────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "  Step 2: Mount System volume ($SYSTEM_DEV) writable"
echo "------------------------------------------------------------"

# bless --setBoot --snapshot requires a WRITABLE mount. Recovery auto-mounts the
# system volume read-only/sealed at /Volumes/Macintosh HD. We must:
#   1. Detect if it's already mounted (and whether read-only or writable)
#   2. If read-only: unmount it, then remount writable at a known path
#   3. If not mounted: mount it writable

MOUNT_POINT=""
RW_MOUNT="/System/Volumes/Update/mnt1"

# Helper: get mount point for a device, handling spaces in paths.
_get_mount_point() {
    diskutil info "$1" 2>/dev/null \
        | awk '/Mount Point:/{sub(/.*Mount Point:[[:space:]]*/, ""); print; exit}'
}

# Check if already mounted
EXISTING_AT=$(_get_mount_point "$SYSTEM_DEV")

if [ -n "$EXISTING_AT" ]; then
    # Check if the mount is read-only or sealed
    _MOUNT_LINE=$(mount | grep "^$SYSTEM_DEV ")
    if echo "$_MOUNT_LINE" | grep -qE "read-only|sealed"; then
        log "System volume mounted read-only at $EXISTING_AT — remounting writable..."
        # Unmount the read-only mount
        _UM_OUT=$(diskutil unmount "$SYSTEM_DEV" 2>&1) || true
        log "  Unmount: $_UM_OUT"
        sleep 1
        EXISTING_AT=""  # force remount below
    else
        ok "System volume already mounted writable at $EXISTING_AT"
        MOUNT_POINT="$EXISTING_AT"
    fi
fi

# Mount writable if needed
if [ -z "$MOUNT_POINT" ]; then
    mkdir -p "$RW_MOUNT" 2>/dev/null || true

    # Try mount_apfs first (gives writable mount at a predictable path)
    _MA_OUT=$(mount_apfs -o nobrowse "$SYSTEM_DEV" "$RW_MOUNT" 2>&1)
    _MA_RET=$?
    if [ $_MA_RET -eq 0 ]; then
        ok "System volume mounted writable at $RW_MOUNT"
        MOUNT_POINT="$RW_MOUNT"
    else
        log "mount_apfs failed: $_MA_OUT"
        # Fallback: diskutil mount, then check if writable
        log "Trying diskutil mount..."
        _DU_OUT=$(diskutil mount "$SYSTEM_DEV" 2>&1)
        _DU_RET=$?
        log "  diskutil: $_DU_OUT"
        if [ $_DU_RET -eq 0 ]; then
            MOUNT_POINT=$(_get_mount_point "$SYSTEM_DEV")
            if [ -n "$MOUNT_POINT" ]; then
                # Verify it's writable
                _ML=$(mount | grep "^$SYSTEM_DEV ")
                if echo "$_ML" | grep -qE "read-only|sealed"; then
                    warn "diskutil mounted read-only at $MOUNT_POINT — bless may fail"
                else
                    ok "System volume mounted at $MOUNT_POINT"
                fi
            else
                err "diskutil reported success but volume not found in mount table."
                exit 1
            fi
        else
            err "Could not mount $SYSTEM_DEV."
            err "  mount_apfs: $_MA_OUT"
            err "  diskutil:   $_DU_OUT"
            err ""
            err "Current mount table:"
            mount 2>&1 | sed 's/^/  /'
            exit 1
        fi
    fi
fi

[ -z "$MOUNT_POINT" ] && { err "Could not determine system volume mount point."; exit 1; }

# ── Step 3: Verify snapshot exists on the volume ─────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "  Step 3: Verify snapshot $TARGET_UUID"
echo "------------------------------------------------------------"

SNAP_CHECK=$(diskutil apfs listSnapshots "$SYSTEM_ID" 2>/dev/null || true)
if [ -z "$SNAP_CHECK" ] || echo "$SNAP_CHECK" | grep -q "Error"; then
    # Volume not mounted — try snapshot slice
    _SL=$(diskutil list "$CONTAINER" 2>/dev/null | awk '/APFS Snapshot/{print $NF; exit}')
    [ -n "$_SL" ] && SNAP_CHECK=$(diskutil apfs listSnapshots "$_SL" 2>/dev/null || true)
fi
if echo "$SNAP_CHECK" | grep -q "$TARGET_UUID"; then
    ok "Snapshot confirmed on $SYSTEM_DEV"
else
    warn "UUID $TARGET_UUID not found in snapshot list."
    echo ""
    echo "  Available snapshots:"
    echo "$SNAP_CHECK" | grep -E "^\+--|Name:" || echo "  (none found)"
    echo ""
    printf "  Continue anyway? [y/N]: "
    read -r CONT < /dev/tty
    case "$CONT" in
        y|Y|yes|YES) log "Continuing..." ;;
        *) die "Aborted." ;;
    esac
fi

# ── Step 4: bless ─────────────────────────────────────────────────────────────
echo ""
echo "------------------------------------------------------------"
echo "  Step 4: bless --setBoot --snapshot $TARGET_UUID"
echo "------------------------------------------------------------"
echo ""
log "Running bless — if prompted for a password, enter it below."
echo ""

# Run bless with stdout visible (so any auth prompts appear on the terminal).
# stderr is captured to a temp file so error details are available on failure.
_BLESS_TMP=$(mktemp)
bless --mount "$MOUNT_POINT" --setBoot --snapshot "$TARGET_UUID" 2>"$_BLESS_TMP"
_BLESS_RET=$?
_BLESS_ERR=$(cat "$_BLESS_TMP")
rm -f "$_BLESS_TMP"

if [ $_BLESS_RET -eq 0 ]; then
    ok "bless succeeded — snapshot set as boot target"
else
    err "bless failed (exit $_BLESS_RET): $_BLESS_ERR"
    err ""
    if echo "$_BLESS_ERR" | grep -qi "read-only"; then
        err "  Volume is mounted read-only. bless needs a writable mount."
        err "  Try unmounting and remounting manually:"
        err "    diskutil unmount $SYSTEM_DEV"
        err "    mount_apfs -o nobrowse $SYSTEM_DEV /System/Volumes/Update/mnt1"
        err "    bless --mount /System/Volumes/Update/mnt1 --setBoot --snapshot $TARGET_UUID"
    elif echo "$_BLESS_ERR" | grep -q "UUID folder"; then
        err "  Preboot UUID folder missing. Check:"
        err "    ls $PREBOOT_MOUNT"
    fi
    err "  Verify SIP is disabled: csrutil status"
    err "  Verify snapshot exists: diskutil apfs listSnapshots $SYSTEM_ID"
    exit 1
fi

# ── Step 5: Confirm & reboot ──────────────────────────────────────────────────
echo ""
echo "============================================================"
ok "Boot snapshot successfully set."
echo ""
echo "  Next boot will use snapshot:"
echo "  $TARGET_UUID"
echo ""
printf "  Reboot now? [Y/n]: "
read -r DO_REBOOT < /dev/tty
case "$DO_REBOOT" in
    n|N|no|NO)
        log "Reboot skipped. Run 'reboot' when ready."
        ;;
    *)
        log "Rebooting..."
        reboot
        ;;
esac
