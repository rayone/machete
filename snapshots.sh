#!/bin/bash
# ==============================================================================
# SNAPSHOT MANAGER - List and Delete APFS Snapshots
#
# USAGE:
#   sudo ./snapshots.sh              # Interactive selection
#   sudo ./snapshots.sh list         # List all snapshots
#   sudo ./snapshots.sh delete <uuid> # Delete specific snapshot
#   sudo ./snapshots.sh delete-all   # Delete all but current boot
#
# WHAT THIS DOES:
#   1. Lists all APFS snapshots on the system volume
#   2. Identifies current boot snapshot (protected)
#   3. Allows safe deletion of non-boot snapshots
#
# WARNING:
#   - Cannot delete the current boot snapshot
#   - Deleting restore snapshots removes rollback points
#   - Some snapshots may be OS-managed (auto-created)
# ==============================================================================

set -uo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
ok()   { echo "${GREEN}  OK   $*${RESET}"; }
warn() { echo "${YELLOW}  WARN $*${RESET}"; }
err()  { echo "${RED}  ERR  $*${RESET}"; }
log()  { echo "  ...  $*"; }
die()  { err "$*"; exit 1; }

# ── Must be root ───────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    die "Must be run as root: sudo $0"
fi

# ── Find volume with snapshots ─────────────────────────────────────────────────
# On modern macOS, snapshots can be on either System or Data volume.
# We look for volumes that have snapshots.
log "Detecting volume with snapshots..."

SNAP_VOL=""
for vol in $(diskutil apfs list 2>/dev/null | grep -E "APFS Volume Disk.*Role.*(System|Data)" | awk '{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]/) {print $i; break}}'); do
    if diskutil apfs listSnapshots "$vol" 2>/dev/null | grep -q "^\+--"; then
        SNAP_VOL="$vol"
        break
    fi
done

if [ -z "$SNAP_VOL" ]; then
    # Fallback: find any APFS volume
    SNAP_VOL=$(diskutil apfs list 2>/dev/null \
        | grep -E "APFS Volume Disk.*Role.*(System|Data)" \
        | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^disk[0-9]/) {print $i; exit}}')
fi

[ -z "$SNAP_VOL" ] && die "Could not find APFS volume"
SYSTEM_DEV="/dev/$SNAP_VOL"
CONTAINER=$(echo "$SNAP_VOL" | sed 's/s[0-9]*$//')

log "  Volume: $SYSTEM_DEV"

# ── Get snapshots ──────────────────────────────────────────────────────────────
get_snapshots() {
    diskutil apfs listSnapshots "$SNAP_VOL" 2>/dev/null
}

parse_snapshots() {
    local snap_data="$1"
    SNAP_UUIDS=()
    SNAP_NAMES=()
    SNAP_XIDS=()
    SNAP_SIZES=()
    
    local _cur_uuid="" _cur_name="" _cur_xid="" _cur_size=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^\+--[[:space:]]([0-9A-F-]{36}) ]]; then
            if [ -n "$_cur_uuid" ]; then
                SNAP_UUIDS+=("$_cur_uuid")
                SNAP_NAMES+=("$_cur_name")
                SNAP_XIDS+=("$_cur_xid")
                SNAP_SIZES+=("$_cur_size")
            fi
            _cur_uuid="${BASH_REMATCH[1]}"
            _cur_name=""
            _cur_xid=""
            _cur_size=""
        elif [[ "$line" =~ Name:[[:space:]]+(.+) ]]; then
            _cur_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ XID:[[:space:]]+([0-9]+) ]]; then
            _cur_xid="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ "Estimated Size"[[:space:]]*:[[:space:]]*(.+) ]]; then
            _cur_size="${BASH_REMATCH[1]}"
        fi
    done <<< "$snap_data"
    
    # Don't forget last snapshot
    if [ -n "$_cur_uuid" ]; then
        SNAP_UUIDS+=("$_cur_uuid")
        SNAP_NAMES+=("$_cur_name")
        SNAP_XIDS+=("$_cur_xid")
        SNAP_SIZES+=("$_cur_size")
    fi
}

find_boot_snapshot() {
    local snap_data="$1"
    echo "$snap_data" | grep -B1 "Will root to" | grep -E "^\+--" | awk '{print $2}'
}

format_size() {
    local size="$1"
    if [ -z "$size" ]; then
        echo "-"
    elif [[ "$size" =~ ([0-9]+)\ ([KMG])B ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K) printf "%.0f KB" "$num" ;;
            M) printf "%.0f MB" "$num" ;;
            G) printf "%.1f GB" "$num" ;;
            *) echo "$size" ;;
        esac
    else
        echo "$size"
    fi
}

list_snapshots() {
    echo ""
    echo "============================================================"
    echo "  APFS SNAPSHOTS ON $SYSTEM_DEV"
    echo "============================================================"
    echo ""
    
    local snap_data
    snap_data=$(get_snapshots)
    
    if [ -z "$snap_data" ]; then
        warn "No snapshots found on $SYSTEM_DEV"
        return 1
    fi
    
    parse_snapshots "$snap_data"
    
    if [ ${#SNAP_UUIDS[@]} -eq 0 ]; then
        warn "No snapshots found"
        return 1
    fi
    
    local boot_uuid
    boot_uuid=$(find_boot_snapshot "$snap_data")
    
    local total_count=${#SNAP_UUIDS[@]}
    local boot_count=0
    local restore_count=0
    local debloat_count=0
    
    for i in "${!SNAP_UUIDS[@]}"; do
        local uuid="${SNAP_UUIDS[$i]}"
        local name="${SNAP_NAMES[$i]}"
        local xid="${SNAP_XIDS[$i]}"
        local size="${SNAP_SIZES[$i]}"
        local num=$((i + 1))
        
        # Determine snapshot type
        local type=""
        local is_boot=false
        local protected=""
        
        if [ "$uuid" = "$boot_uuid" ]; then
            type="CURRENT BOOT"
            is_boot=true
            protected="${CYAN}[PROTECTED]${RESET}"
            boot_count=$((boot_count + 1))
        elif echo "$name" | grep -q "debloat\.restore"; then
            type="debloat restore"
            debloat_count=$((debloat_count + 1))
        elif echo "$name" | grep -q "bless"; then
            type="debloat boot"
            debloat_count=$((debloat_count + 1))
        elif echo "$name" | grep -q "os\.update"; then
            type="macOS update"
            restore_count=$((restore_count + 1))
        else
            type="$name"
        fi
        
        # Size formatting
        local size_fmt
        size_fmt=$(format_size "$size")
        
        printf "  ${BOLD}[%2d]${RESET} %s %s\n" "$num" "$type" "$protected"
        printf "        UUID:  %s\n" "$uuid"
        [ -n "$xid" ] && printf "        XID:   %s\n" "$xid"
        [ -n "$size" ] && printf "        Size:  %s\n" "$size_fmt"
        echo ""
    done
    
    echo "  ────────────────────────────────────────────────────────────"
    printf "  Total: %d snapshots" "$total_count"
    [ $boot_count -gt 0 ] && printf "  |  Boot: %d" "$boot_count"
    [ $debloat_count -gt 0 ] && printf "  |  Debloat: %d" "$debloat_count"
    echo ""
    echo ""
}

delete_snapshot() {
    local uuid="$1"
    
    if [ -z "$uuid" ]; then
        die "Usage: $0 delete <uuid>"
    fi
    
    local snap_data
    snap_data=$(get_snapshots)
    local boot_uuid
    boot_uuid=$(find_boot_snapshot "$snap_data")
    
    if [ "$uuid" = "$boot_uuid" ]; then
        err "Cannot delete the current boot snapshot!"
        err "Boot snapshot: $uuid"
        err ""
        err "To remove this snapshot, first boot into a different snapshot:"
        err "  1. Run: ./restore.sh"
        err "  2. Select a different snapshot"
        err "  3. Reboot and try again"
        exit 1
    fi
    
    # Find snapshot name for confirmation
    local snap_name="(unknown)"
    parse_snapshots "$snap_data"
    for i in "${!SNAP_UUIDS[@]}"; do
        if [ "${SNAP_UUIDS[$i]}" = "$uuid" ]; then
            snap_name="${SNAP_NAMES[$i]}"
            break
        fi
    done
    
    echo ""
    warn "About to DELETE snapshot:"
    echo ""
    echo "  UUID: $uuid"
    echo "  Name: $snap_name"
    echo ""
    printf "  Confirm? [y/N]: "
    read -r confirm < /dev/tty
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log "Cancelled"
        return 0
    fi
    
    echo ""
    log "Deleting snapshot $uuid..."
    
    if diskutil apfs deleteSnapshot "$SYSTEM_DEV" -uuid "$uuid" 2>&1; then
        ok "Snapshot deleted: $uuid"
    else
        err "Failed to delete snapshot"
        exit 1
    fi
}

delete_all_non_boot() {
    local snap_data
    snap_data=$(get_snapshots)
    local boot_uuid
    boot_uuid=$(find_boot_snapshot "$snap_data")
    
    parse_snapshots "$snap_data"
    
    local to_delete=()
    for i in "${!SNAP_UUIDS[@]}"; do
        if [ "${SNAP_UUIDS[$i]}" != "$boot_uuid" ]; then
            to_delete+=("${SNAP_UUIDS[$i]}")
        fi
    done
    
    if [ ${#to_delete[@]} -eq 0 ]; then
        ok "No snapshots to delete (only boot snapshot exists)"
        return 0
    fi
    
    echo ""
    warn "About to DELETE ${#to_delete[@]} snapshot(s):"
    echo ""
    
    for uuid in "${to_delete[@]}"; do
        for i in "${!SNAP_UUIDS[@]}"; do
            if [ "${SNAP_UUIDS[$i]}" = "$uuid" ]; then
                printf "  - %s (%s)\n" "$uuid" "${SNAP_NAMES[$i]}"
                break
            fi
        done
    done
    
    echo ""
    printf "  This action cannot be undone. Confirm? [y/N]: "
    read -r confirm < /dev/tty
    
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log "Cancelled"
        return 0
    fi
    
    echo ""
    local deleted=0
    local failed=0
    
    for uuid in "${to_delete[@]}"; do
        log "Deleting $uuid..."
        if diskutil apfs deleteSnapshot "$SYSTEM_DEV" -uuid "$uuid" 2>/dev/null; then
            deleted=$((deleted + 1))
        else
            warn "Failed to delete: $uuid"
            failed=$((failed + 1))
        fi
    done
    
    echo ""
    ok "Deleted: $deleted  |  Failed: $failed"
}

interactive_delete() {
    list_snapshots
    
    if [ ${#SNAP_UUIDS[@]} -eq 0 ]; then
        return 1
    fi
    
    echo "  ────────────────────────────────────────────────────────────"
    echo "  Enter snapshot number to DELETE, or 'q' to quit"
    echo ""
    printf "  Choice: "
    read -r choice < /dev/tty
    
    if [ "$choice" = "q" ] || [ "$choice" = "Q" ]; then
        log "Cancelled"
        return 0
    fi
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#SNAP_UUIDS[@]}" ]; then
        local uuid="${SNAP_UUIDS[$((choice - 1))]}"
        delete_snapshot "$uuid"
    else
        die "Invalid choice: $choice"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
case "${1:-}" in
    list)
        list_snapshots
        ;;
    delete)
        delete_snapshot "${2:-}"
        ;;
    delete-all)
        delete_all_non_boot
        ;;
    "")
        interactive_delete
        ;;
    *)
        err "Unknown command: $1"
        echo ""
        echo "Usage:"
        echo "  $0              Interactive snapshot deletion"
        echo "  $0 list         List all snapshots"
        echo "  $0 delete <uuid> Delete specific snapshot"
        echo "  $0 delete-all   Delete all non-boot snapshots"
        exit 1
        ;;
esac