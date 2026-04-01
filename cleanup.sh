#!/bin/bash
# ==============================================================================
# POST-DEBLOAT CLEANUP — macOS 26.4 / Apple M5 Max
# Reads manifest.yaml to determine what was removed, then performs all cleanup
# tasks that require a running system (unlike debloat.sh SSV phases).
#
# USAGE:
#   sudo ./cleanup.sh --features f1,f2,... [OPTIONS]
#
# OPTIONS:
#   --features  f1,f2,...  Features that were debloated (comma-separated, required)
#   --dry-run              Show what would change, make no changes
#   --yes                  Skip all confirmation prompts
#   --list                 List all cleanup tasks and exit
#
# PHASES:
#   Phase 1 — Group Containers:    Remove ~/Library/Group Containers/* for removed features
#   Phase 2 — CoreSpotlight:       Purge stale receiver plists, FileProvider domains,
#                                  IMCoreSpotlight touchfile
#   Phase 3 — Spotlight Rules:     Remove removed-app bundle IDs from EnabledPreferenceRules
#   Phase 4 — LaunchServices:      Rebuild lsregister database
#   Phase 5 — Icon Services Cache: Clear stale icon cache
#   Phase 6 — Spotlight Reindex:   mdutil -E / to force clean rebuild
#
# CALLED AUTOMATICALLY by debloat.sh Phase G after user data cleanup.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.yaml"
LOG="$SCRIPT_DIR/cleanup-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
YES_ALL=false
LIST_ONLY=false
FEATURE_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --yes)        YES_ALL=true ;;
        --list)       LIST_ONLY=true ;;
        --features)   FEATURE_FILTER="$2"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exec > >(tee -a "$LOG") 2>&1

ts()     { date '+%H:%M:%S'; }
log()    { echo "  [$(ts)] $*"; }
ok()     { echo "  [$(ts)] OK  $*"; }
warn()   { echo "  [$(ts)] WARN $*"; }
err()    { echo "  [$(ts)] ERR  $*"; }
header() { echo ""; echo "=============================================================================="; echo "  $*"; echo "=============================================================================="; }
sep()    { echo "  ──────────────────────────────────────────────────────────────────────────"; }

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = true ]; then
    header "POST-DEBLOAT CLEANUP — task list"
    echo ""
    echo "  Phase 1  Group Containers     ~/Library/Group Containers/* for removed features"
    echo "  Phase 2  CoreSpotlight        Stale receiver plists, FileProvider domains,"
    echo "                                 IMCoreSpotlight touchfile"
    echo "  Phase 3  Spotlight Rules      Remove removed-app bundle IDs from EnabledPreferenceRules"
    echo "  Phase 4  LaunchServices       Rebuild lsregister database"
    echo "  Phase 5  Icon Services Cache  Clear stale icon cache"
    echo "  Phase 6  Spotlight Reindex    mdutil -E / (full clean rebuild)"
    echo ""
    echo "  Usage: sudo ./cleanup.sh --features f1,f2,... [--dry-run] [--yes]"
    exit 0
fi

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ]; then
    err "Must be run as root: sudo ./cleanup.sh --features ..."
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve real user (sudo-safe)
# ---------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER=$(logname 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER="$USER"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "$(id -u)")

header "POST-DEBLOAT CLEANUP — macOS $(sw_vers -productVersion)"
log "Manifest: $MANIFEST"
log "Log:      $LOG"
log "Dry run:  $DRY_RUN"
log "User:     $REAL_USER (home: $REAL_HOME, uid: $REAL_UID)"

# ---------------------------------------------------------------------------
# Feature list
# ---------------------------------------------------------------------------
if [ -z "$FEATURE_FILTER" ]; then
    err "--features is required. Example: --features icloud,mail,siri_and_intelligence"
    exit 1
fi

IFS=',' read -ra FEATURES <<< "$FEATURE_FILTER"
log "Features: ${FEATURES[*]}"

# ---------------------------------------------------------------------------
# Inline Perl YAML parser — identical subset to debloat.sh, supports
# user_group_containers and Spotlight bundle ID derivation from user_containers.
# ---------------------------------------------------------------------------
PARSER_PL=$(mktemp /tmp/.cleanup_parser_XXXXXX.pl)
trap 'rm -f "$PARSER_PL"' EXIT

cat > "$PARSER_PL" << 'PLEOF'
#!/usr/bin/env perl
use strict; use warnings;

sub load_manifest {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!\n";
    my @lines = <$fh>; close $fh;
    my (%root, $feat_name, $feat, $key);
    for my $raw (@lines) {
        chomp $raw; my $s = $raw; $s =~ s/^\s+//;
        next if $s eq '' || $s =~ /^#/;
        my $ind = length($raw) - length($s);
        if ($ind == 0 && $s =~ /^([A-Za-z_][A-Za-z0-9_ -]*):\s*$/) {
            $feat_name = $1; $feat = {}; $root{$feat_name} = $feat; $key = undef; next;
        }
        next unless defined $feat;
        if ($ind == 2 && $s =~ /^([a-z_][a-z0-9_]*):\s*(.*)/) {
            $key = $1; my $v = $2;
            $v =~ s/\s+#.*$//; $v =~ s/^\s+|\s+$//g;
            $feat->{$key} = ($v eq '' || $v eq '{}') ? {} : ($v eq '[]') ? [] : $v; next;
        }
        if ($ind == 4 && $s =~ /^- (.*)/) {
            my $v = $1; $v =~ s/\s+#.*$//; $v =~ s/^\s+|\s+$//g;
            $feat->{$key} = [] unless ref $feat->{$key} eq 'ARRAY';
            push @{$feat->{$key}}, $v;
        }
    }
    return \%root;
}

sub get_array {
    my ($root, $fn, $key) = @_;
    my $feat = $root->{$fn} // {}; my $v = $feat->{$key} // [];
    return () unless defined $v;
    return @$v if ref $v eq 'ARRAY';
    return ($v) if !ref $v && $v =~ /\S/;
    return ();
}

my ($manifest, $cmd, @feats) = @ARGV;
my $root = load_manifest($manifest);

if ($cmd eq 'dump_group_containers') {
    for my $fn (@feats) {
        for my $gc (get_array($root, $fn, 'user_group_containers')) {
            print "$gc\n";
        }
    }
}
elsif ($cmd eq 'dump_spotlight_bundles') {
    # Emit bundle IDs for Spotlight EnabledPreferenceRules pruning.
    # Derived from: user_containers, user_prefs (label only → com.apple.<label>),
    # and a per-feature hardcoded supplement for non-obvious IDs.
    my %seen;
    my %supplements = (
        icloud             => [qw(com.apple.CloudDocs.iCloudDriveFileProvider
                                  com.apple.iCloud System.iCloudDrive)],
        mail               => [qw(com.apple.mail)],
        messages_facetime  => [qw(com.apple.MobileSMS com.apple.FaceTime)],
        calendar_reminders => [qw(com.apple.iCal com.apple.CalendarUI com.apple.reminders)],
        contacts           => [qw(com.apple.AddressBook)],
        maps               => [qw(com.apple.Maps)],
        photos             => [qw(com.apple.Photos Domain.IMAGE)],
        music              => [qw(com.apple.Music com.apple.TV com.apple.podcasts
                                  Domain.MUSIC Domain.MOVIES)],
        news_stocks_weather=> [qw(com.apple.news com.apple.stocks com.apple.weather)],
        notes_books        => [qw(com.apple.Notes com.apple.iBooks)],
        homekit            => [qw(com.apple.Home)],
        game_center        => [qw(com.apple.gamecenter)],
        wallet             => [qw(com.apple.Passbook com.apple.Passwords)],
        shortcuts_automator=> [qw(com.apple.shortcuts com.apple.automator
                                  System.iphoneApps)],
        misc_apps          => [qw(com.apple.VoiceMemos com.apple.Tips com.apple.tips)],
        find_my            => [qw(com.apple.findmy)],
        app_store_updates  => [qw(com.apple.AppStore)],
        siri_and_intelligence => [qw(com.apple.Siri)],
    );
    for my $fn (@feats) {
        # From user_containers
        for my $c (get_array($root, $fn, 'user_containers')) {
            print "$c\n" unless $seen{$c}++;
        }
        # From user_prefs
        for my $p (get_array($root, $fn, 'user_prefs')) {
            my $bid = "com.apple.$p";
            print "$bid\n" unless $seen{$bid}++;
            print "$p\n" unless $seen{$p}++;
        }
        # Supplements
        for my $bid (@{$supplements{$fn} // []}) {
            print "$bid\n" unless $seen{$bid}++;
        }
    }
}
elsif ($cmd eq 'has_feature') {
    # Exit 0 if any of the remaining args are in @feats
    my ($needle) = @feats;
    # @feats here is rest of ARGV after $cmd
    exit 0 if grep { $_ eq $needle } @feats;
    exit 1;
}
PLEOF

# Helper: check if a feature is in FEATURES array
has_feature() {
    local needle="$1"
    for f in "${FEATURES[@]}"; do
        [ "$f" = "$needle" ] && return 0
    done
    return 1
}

# Helper: run as real user
run_as_user() { sudo -u "$REAL_USER" "$@"; }

# Helper: safe rm with dry-run support
safe_rm() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "    [DRY]  rm -rf  $path"
        else
            rm -rf "$path" && ok "Removed: $path" || warn "Failed to remove: $path"
        fi
    fi
}

DELETED=0
SKIPPED=0

# ===========================================================================
# PHASE 1 — GROUP CONTAINERS
# ===========================================================================
header "PHASE 1: GROUP CONTAINERS"

GC_BASE="$REAL_HOME/Library/Group Containers"

while IFS= read -r gc_id; do
    [ -z "$gc_id" ] && continue
    gc_path="$GC_BASE/$gc_id"
    if [ -e "$gc_path" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo "    [DRY]  rm -rf  \"$gc_path\""
            DELETED=$((DELETED + 1))
        else
            rm -rf "$gc_path" \
                && { ok "Removed group container: $gc_id"; DELETED=$((DELETED + 1)); } \
                || { warn "Failed: $gc_id"; SKIPPED=$((SKIPPED + 1)); }
        fi
    else
        log "Already absent: $gc_id"
        SKIPPED=$((SKIPPED + 1))
    fi
done < <(perl "$PARSER_PL" "$MANIFEST" dump_group_containers "${FEATURES[@]}")

log "Group containers removed: $DELETED  absent/skipped: $SKIPPED"

# ===========================================================================
# PHASE 2 — CORESPOTLIGHT RECEIVER PLISTS
# ===========================================================================
header "PHASE 2: CORESPOTLIGHT RECEIVER PLISTS"

CS_META="$REAL_HOME/Library/Metadata/CoreSpotlight"

# Bundle IDs that belong to removed features, keyed by receiver plist.
# Determined from corespotlight.log analysis.

# ── 2a. Stop mds + corespotlightd so we can safely modify their plists ──────
if [ "$DRY_RUN" = false ]; then
    log "[2a] Stopping mds and corespotlightd..."
    launchctl stop com.apple.metadata.mds 2>/dev/null || true
    run_as_user launchctl stop com.apple.corespotlightd 2>/dev/null || true
    sleep 1
fi

# ── 2b. Receiver plist: coreduet ─────────────────────────────────────────────
# Stale content types from removed features: mail, messages_facetime, calendar_reminders
COREDUET_STALE=(
    "public.email-message"
    "com.apple.mail.emlx"
    "com.apple.ichat.transcript"
    "com.apple.ical.ics.event"
    "public.calendar-event"
)
COREDUET_PLIST="$CS_META/com.apple.corespotlight.receiver.coreduet.plist"
if [ -f "$COREDUET_PLIST" ]; then
    log "[2b] Pruning coreduet receiver plist..."
    stale_removed=0
    for ct in "${COREDUET_STALE[@]}"; do
        # Only remove if the owning feature was debloated
        should_remove=false
        case "$ct" in
            "public.email-message"|"com.apple.mail.emlx")
                has_feature "mail" && should_remove=true ;;
            "com.apple.ichat.transcript")
                has_feature "messages_facetime" && should_remove=true ;;
            "com.apple.ical.ics.event"|"public.calendar-event")
                has_feature "calendar_reminders" && should_remove=true ;;
        esac
        [ "$should_remove" = false ] && continue

        if [ "$DRY_RUN" = true ]; then
            echo "    [DRY]  PlistBuddy delete cts entry: $ct from coreduet plist"
        else
            # Find and delete by value from the cts array
            idx=$(run_as_user /usr/libexec/PlistBuddy -c "Print :cts" "$COREDUET_PLIST" 2>/dev/null \
                | grep -n "= $ct$" | head -1 | cut -d: -f1)
            if [ -n "$idx" ]; then
                # PlistBuddy arrays are 0-indexed; grep line numbers are 1-indexed within the print block
                # Calculate 0-based array index: subtract 1 for the "Array {" header line
                arr_idx=$(( idx - 2 ))
                if [ "$arr_idx" -ge 0 ] 2>/dev/null; then
                    run_as_user /usr/libexec/PlistBuddy -c "Delete :cts:$arr_idx" "$COREDUET_PLIST" 2>/dev/null \
                        && { ok "  Removed coreduet cts: $ct"; stale_removed=$((stale_removed+1)); } \
                        || warn "  PlistBuddy delete failed for: $ct"
                fi
            fi
        fi
    done
    log "coreduet stale entries removed: $stale_removed"
fi

# ── 2c. Receiver plist: textunderstandingd ───────────────────────────────────
# bids for removed features: icloud, notes_books, calendar_reminders, mail, messages_facetime
TUD_PLIST="$CS_META/com.apple.corespotlight.receiver.textunderstandingd.plist"
# Format: "bundle_id feature" — use plain array, parse with read
TUD_ENTRIES=(
    "com.apple.CloudDocs.iCloudDriveFileProvider icloud"
    "com.apple.Notes notes_books"
    "com.apple.CalendarUI calendar_reminders"
    "com.apple.mail mail"
    "com.apple.MobileSMS messages_facetime"
    "com.apple.email.SearchIndexer mail"
)
if [ -f "$TUD_PLIST" ]; then
    log "[2c] Pruning textunderstandingd receiver plist..."
    tud_removed=0
    for entry in "${TUD_ENTRIES[@]}"; do
        bid="${entry%% *}"
        feature="${entry##* }"
        has_feature "$feature" || continue
        if [ "$DRY_RUN" = true ]; then
            echo "    [DRY]  PlistBuddy delete bids entry: $bid from textunderstandingd plist"
        else
            idx=$(run_as_user /usr/libexec/PlistBuddy -c "Print :bids" "$TUD_PLIST" 2>/dev/null \
                | grep -n "= $bid$" | head -1 | cut -d: -f1)
            if [ -n "$idx" ]; then
                arr_idx=$(( idx - 2 ))
                if [ "$arr_idx" -ge 0 ] 2>/dev/null; then
                    run_as_user /usr/libexec/PlistBuddy -c "Delete :bids:$arr_idx" "$TUD_PLIST" 2>/dev/null \
                        && { ok "  Removed textunderstandingd bid: $bid"; tud_removed=$((tud_removed+1)); } \
                        || warn "  PlistBuddy delete failed for: $bid"
                fi
            fi
        fi
    done
    log "textunderstandingd stale bids removed: $tud_removed"
fi

# ── 2d. Receiver plist: photos ───────────────────────────────────────────────
# bids: com.apple.MobileSMS (messages_facetime), com.apple.Notes (notes_books),
#       com.apple.Stickers (misc_apps)
PHOTOS_PLIST="$CS_META/com.apple.corespotlight.receiver.photos.plist"
PHOTOS_ENTRIES=(
    "com.apple.MobileSMS messages_facetime"
    "com.apple.Notes notes_books"
    "com.apple.Stickers misc_apps"
)
if [ -f "$PHOTOS_PLIST" ]; then
    log "[2d] Pruning photos receiver plist..."
    ph_removed=0
    for entry in "${PHOTOS_ENTRIES[@]}"; do
        bid="${entry%% *}"
        feature="${entry##* }"
        has_feature "$feature" || continue
        if [ "$DRY_RUN" = true ]; then
            echo "    [DRY]  PlistBuddy delete bids entry: $bid from photos plist"
        else
            idx=$(run_as_user /usr/libexec/PlistBuddy -c "Print :bids" "$PHOTOS_PLIST" 2>/dev/null \
                | grep -n "= $bid$" | head -1 | cut -d: -f1)
            if [ -n "$idx" ]; then
                arr_idx=$(( idx - 2 ))
                if [ "$arr_idx" -ge 0 ] 2>/dev/null; then
                    run_as_user /usr/libexec/PlistBuddy -c "Delete :bids:$arr_idx" "$PHOTOS_PLIST" 2>/dev/null \
                        && { ok "  Removed photos bid: $bid"; ph_removed=$((ph_removed+1)); } \
                        || warn "  PlistBuddy delete failed for: $bid"
                fi
            fi
        fi
    done
    log "photos stale bids removed: $ph_removed"
fi

# ── 2e. FileProviderDomains.plist ─────────────────────────────────────────────
# Contains iCloud Drive FileProvider domain — remove if icloud was debloated
FPD_PLIST="$CS_META/FileProviderDomains.plist"
if has_feature "icloud" && [ -f "$FPD_PLIST" ]; then
    log "[2e] Removing FileProviderDomains.plist (iCloud Drive domain)..."
    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY]  rm -f  \"$FPD_PLIST\""
    else
        run_as_user rm -f "$FPD_PLIST" \
            && ok "Removed FileProviderDomains.plist" \
            || warn "Failed to remove FileProviderDomains.plist"
    fi
fi

# ── 2f. IMCoreSpotlight touchfile ─────────────────────────────────────────────
# messages_facetime leaves behind com.apple.IMCoreSpotlight.plist in Preferences
IMCS_PLIST="$REAL_HOME/Library/Preferences/com.apple.IMCoreSpotlight.plist"
if has_feature "messages_facetime" && [ -f "$IMCS_PLIST" ]; then
    log "[2f] Removing IMCoreSpotlight preferences (Messages/FaceTime stale touchfile)..."
    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY]  rm -f  \"$IMCS_PLIST\""
    else
        run_as_user rm -f "$IMCS_PLIST" \
            && ok "Removed IMCoreSpotlight plist" \
            || warn "Failed to remove IMCoreSpotlight plist"
    fi
fi

# ── 2g. Mail CoreSpotlight application scripts container ─────────────────────
MAIL_SCRIPTS="$REAL_HOME/Library/Application Scripts/com.apple.mail.SpotlightIndexExtension"
if has_feature "mail" && [ -d "$MAIL_SCRIPTS" ]; then
    log "[2g] Removing Mail SpotlightIndexExtension scripts container..."
    if [ "$DRY_RUN" = true ]; then
        echo "    [DRY]  rm -rf  \"$MAIL_SCRIPTS\""
    else
        run_as_user rm -rf "$MAIL_SCRIPTS" \
            && ok "Removed Mail SpotlightIndexExtension scripts" \
            || warn "Failed to remove Mail SpotlightIndexExtension scripts"
    fi
fi

# ── 2h. Restart mds + corespotlightd ─────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
    log "[2h] Restarting mds and corespotlightd..."
    launchctl kickstart -k system/com.apple.metadata.mds 2>/dev/null || true
    run_as_user launchctl kickstart -k "gui/$REAL_UID/com.apple.corespotlightd" 2>/dev/null || true
    sleep 1
    ok "mds and corespotlightd restarted"
fi

# ===========================================================================
# PHASE 3 — SPOTLIGHT ENABLEDPREFERENCERULES
# ===========================================================================
header "PHASE 3: SPOTLIGHT ENABLEDPREFERENCERULES"

# Build the set of bundle IDs to remove from Spotlight's EnabledPreferenceRules
# (the list shown in the System Settings → Spotlight screenshot)

log "[3] Reading current Spotlight EnabledPreferenceRules..."

# Collect current rules (bash 3.2 compatible — no mapfile)
CURRENT_RULES=()
while IFS= read -r rule; do
    [ -n "$rule" ] && CURRENT_RULES+=("$rule")
done < <(
    run_as_user defaults read com.apple.Spotlight EnabledPreferenceRules 2>/dev/null \
    | grep -oE '"[^"]*"' | tr -d '"'
)

if [ ${#CURRENT_RULES[@]} -eq 0 ]; then
    log "No EnabledPreferenceRules found — skipping."
else
    log "Current rules (${#CURRENT_RULES[@]}): ${CURRENT_RULES[*]}"

    # Build the set of bundle IDs to remove (bash 3.2 compatible)
    STALE_IDS=()
    while IFS= read -r sid; do
        [ -n "$sid" ] && STALE_IDS+=("$sid")
    done < <(perl "$PARSER_PL" "$MANIFEST" dump_spotlight_bundles "${FEATURES[@]}" | sort -u)

    # Static domain items per feature
    for feat in "${FEATURES[@]}"; do
        case "$feat" in
            music)              STALE_IDS+=("Domain.MUSIC" "Domain.MOVIES") ;;
            photos)             STALE_IDS+=("Domain.IMAGE") ;;
            shortcuts_automator) STALE_IDS+=("System.iphoneApps") ;;
            icloud)             STALE_IDS+=("System.iCloudDrive" "Custom.relatedContents") ;;
        esac
    done

    # Build lookup string for O(n) membership test without associative arrays
    # Delimiter-wrap each stale ID for safe grep
    STALE_LOOKUP=""
    for sid in "${STALE_IDS[@]}"; do
        STALE_LOOKUP="$STALE_LOOKUP|$sid|"
    done

    KEPT_RULES=()
    PRUNED_RULES=()
    for rule in "${CURRENT_RULES[@]}"; do
        if echo "$STALE_LOOKUP" | grep -qF "|${rule}|"; then
            PRUNED_RULES+=("$rule")
        else
            KEPT_RULES+=("$rule")
        fi
    done

    if [ ${#PRUNED_RULES[@]} -eq 0 ]; then
        log "No stale rules found in EnabledPreferenceRules — already clean."
    else
        log "Stale rules to remove (${#PRUNED_RULES[@]}): ${PRUNED_RULES[*]+"${PRUNED_RULES[*]}"}"
        log "Rules to keep (${#KEPT_RULES[@]}): ${KEPT_RULES[*]+"${KEPT_RULES[*]}"}"

        if [ "$DRY_RUN" = true ]; then
            echo "    [DRY]  defaults write com.apple.Spotlight EnabledPreferenceRules (${#KEPT_RULES[@]} entries kept)"
        else
            if [ ${#KEPT_RULES[@]} -eq 0 ]; then
                # All rules removed — write an empty array
                run_as_user defaults write com.apple.Spotlight EnabledPreferenceRules "()" \
                    && ok "EnabledPreferenceRules cleared (all ${#PRUNED_RULES[@]} stale entries removed)" \
                    || warn "Failed to update EnabledPreferenceRules"
            else
                # Build the array plist string for defaults write
                plist_array="("
                first=1
                for rule in "${KEPT_RULES[@]+"${KEPT_RULES[@]}"}"; do
                    [ $first -eq 0 ] && plist_array+=", "
                    plist_array+="\"${rule}\""
                    first=0
                done
                plist_array+=")"

                run_as_user defaults write com.apple.Spotlight EnabledPreferenceRules "$plist_array" \
                    && ok "EnabledPreferenceRules updated: removed ${#PRUNED_RULES[@]} stale entries" \
                    || warn "Failed to update EnabledPreferenceRules"
            fi # end kept/empty branch
        fi # end dry-run check
    fi # end pruned check
fi # end current-rules check

# ===========================================================================
# PHASE 4 — LAUNCHSERVICES DATABASE REBUILD
# ===========================================================================
header "PHASE 4: LAUNCHSERVICES DATABASE REBUILD"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [ "$DRY_RUN" = true ]; then
    echo "    [DRY]  lsregister -kill -seed -r -f"
else
    log "Rebuilding LaunchServices database (this takes 5-15 seconds)..."
    "$LSREGISTER" -kill -seed -r -f 2>/dev/null \
        && ok "LaunchServices database rebuilt" \
        || warn "lsregister exited non-zero (non-fatal)"
fi

# ===========================================================================
# PHASE 5 — ICON SERVICES CACHE
# ===========================================================================
header "PHASE 5: ICON SERVICES CACHE"

# iconservicesd wrote 2.1 GB rebuilding the cache on first boot with removed-app entries.
# Clear it so it rebuilds cleanly on next login.

ICON_DIRS=(
    "/private/var/folders"
)

if [ "$DRY_RUN" = true ]; then
    echo "    [DRY]  find /private/var/folders -name 'com.apple.iconservices' -type d -exec rm -rf {} +"
    echo "    [DRY]  find /private/var/folders -name 'com.apple.iconservices.store' -type d -exec rm -rf {} +"
else
    log "Clearing icon services caches in /private/var/folders..."
    icon_count=0
    while IFS= read -r idir; do
        rm -rf "$idir" && icon_count=$((icon_count + 1))
    done < <(find /private/var/folders -name "com.apple.iconservices" -type d 2>/dev/null)
    while IFS= read -r idir; do
        rm -rf "$idir" && icon_count=$((icon_count + 1))
    done < <(find /private/var/folders -name "com.apple.iconservices.store" -type d 2>/dev/null)
    ok "Icon services cache directories cleared: $icon_count"
fi

# ===========================================================================
# PHASE 6 — SPOTLIGHT REINDEX
# ===========================================================================
header "PHASE 6: SPOTLIGHT REINDEX"

if [ "$DRY_RUN" = true ]; then
    echo "    [DRY]  mdutil -E /"
    echo "    NOTE: Full Spotlight reindex takes 10-30 minutes in the background."
else
    log "Triggering Spotlight full reindex on / ..."
    mdutil -E / 2>/dev/null \
        && ok "Spotlight reindex triggered on /. Indexing runs in background (10-30 min)." \
        || warn "mdutil -E / failed (non-fatal — Spotlight will rebuild incrementally)"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
header "CLEANUP SUMMARY"
log "Features cleaned: ${FEATURES[*]}"
log "Group containers removed: $DELETED"
log "Log: $LOG"
echo ""
if [ "$DRY_RUN" = true ]; then
    log "DRY RUN complete — no changes made."
else
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │  Cleanup complete.                                          │"
    echo "  │  Log off and back in for icon cache to rebuild cleanly.     │"
    echo "  └─────────────────────────────────────────────────────────────┘"
fi
echo ""

exit 0
