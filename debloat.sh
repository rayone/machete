#!/bin/bash
# ==============================================================================
# DEBLOAT EXECUTOR — macOS 26.4 / Apple M5 Max
# Reads manifest.yaml and performs all removal actions.
#
# USAGE:
#   sudo ./debloat.sh [OPTIONS] [feature1 feature2 ...]
#
# OPTIONS:
#   --dry-run      Print what would be done, make no changes
#   --ssv-only     Only perform SSV (sealed system volume) deletions
#   --agents-only  Only disable LaunchAgents/LaunchDaemons
#   --user-only    Only clean user data (containers, prefs, caches)
#   --yes                     Skip all confirmation prompts (non-interactive)
#   --force-no-snapshot       Proceed without restore snapshot (DANGEROUS)
#   --features                Comma-separated list of features to process
#   --skip         Comma-separated list of features to skip
#   --verify       Read-only dependency audit (otool, kextstat, plutil, pluginkit)
#   --list         List all features in manifest and exit
#
# REQUIRES:
#   - SIP disabled:              csrutil disable        (in Recovery)
#   - Authenticated root off:    csrutil authenticated-root disable (in Recovery)
#   - Run as root:               sudo ./debloat.sh
#   - python3 (for YAML parsing): ships with macOS CLT
#
# ARCHITECTURE:
#   Phase A (pre-mount):  Parse manifest, build SSV path list, generate plists
#   Phase B (SSV mount):  Single mount → rm -rf all SSV paths → patches → bless
#                         MUST complete in < 60s (kernel watchdog)
#   Phase C (post-mount): Verify bless, clean old snapshots
#   Phase D (live):       launchctl disable agents/daemons
#   Phase E (user):       Remove containers, prefs, caches, pluginkit suppress
# ==============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/manifest.yaml"
MOUNT_POINT="/System/Volumes/Update/mnt1"
LOG="$SCRIPT_DIR/debloat-$(date +%Y%m%d-%H%M%S).log"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
SSV_ONLY=false
AGENTS_ONLY=false
USER_ONLY=false
VERIFY_ONLY=false
YES_ALL=false
FORCE_NO_SNAPSHOT=false
FEATURE_FILTER=""
SKIP_FILTER=""
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true ;;
        --ssv-only)     SSV_ONLY=true ;;
        --agents-only)  AGENTS_ONLY=true ;;
        --user-only)    USER_ONLY=true ;;
        --verify)       VERIFY_ONLY=true ;;
        --yes)                YES_ALL=true ;;
        --force-no-snapshot)  FORCE_NO_SNAPSHOT=true ;;
        --features)           FEATURE_FILTER="$2"; shift ;;
        --skip)         SKIP_FILTER="$2"; shift ;;
        --list)         LIST_ONLY=true ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exec > >(tee -a "$LOG") 2>&1

ts() { date '+%H:%M:%S'; }
log()  { echo "  [$(ts)] $*"; }
ok()   { echo "  [$(ts)] OK  $*"; }
warn() { echo "  [$(ts)] WARN $*"; }
err()  { echo "  [$(ts)] ERR  $*"; }
header() { echo ""; echo "=============================================================================="; echo "  $*"; echo "=============================================================================="; }

header "DEBLOAT EXECUTOR — macOS $(sw_vers -productVersion)"
log "Manifest: $MANIFEST"
log "Log:      $LOG"
log "Dry run:  $DRY_RUN"

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ] && [ "$VERIFY_ONLY" = false ]; then
    err "Must be run as root (sudo ./debloat.sh)"
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    err "Manifest not found: $MANIFEST"
    exit 1
fi

# perl is our YAML parser — ships with vanilla macOS, no CLT needed.
# python3 is only required for --verify (otool dependency scan).
if ! command -v perl &>/dev/null; then
    err "perl not found (unexpected — perl ships with all macOS versions)"
    exit 1
fi
if [ "$VERIFY_ONLY" = true ] && ! command -v python3 &>/dev/null; then
    err "--verify requires python3 (Xcode CLT): xcode-select --install"
    exit 1
fi

# ---------------------------------------------------------------------------
# YAML parser — stdlib Perl only, no CPAN modules needed.
# Perl ships with every macOS version, requires no CLT.
# Written to /tmp/.debloat_parser_$$.pl at runtime.
# Supports the exact manifest.yaml structure:
#   indent-0  → feature name (top-level key)
#   indent-2  → field key: scalar or start of list/dict
#   indent-4  → list item (- value) or nested key: value
#   indent-6  → list item or key under patches sub-entry
#   indent-8  → key-value inside replacements list-of-dicts
# ---------------------------------------------------------------------------
PARSER_PY="/tmp/.debloat_parser_$$.pl"
cat > "$PARSER_PY" << 'PLEOF'
#!/usr/bin/env perl
use strict;
use warnings;

# ── Load manifest ────────────────────────────────────────────────────────────
sub load {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot open $path: $!\n";
    my @lines = <$fh>;
    close $fh;

    my %root;
    my ($feat, $feat_name, $key, $sub, $sub_key) = (undef, '', undef, undef, undef);

    for my $raw (@lines) {
        chomp $raw;
        my $stripped = $raw;
        $stripped =~ s/^\s+//;
        next if $stripped eq '' || $stripped =~ /^#/;
        my $indent = length($raw) - length($stripped);

        # indent 0 — top-level feature key
        if ($indent == 0) {
            if ($stripped =~ /^([A-Za-z_][A-Za-z0-9_ -]*):\s*$/) {
                $feat_name = $1;
                $feat = {};
                $root{$feat_name} = $feat;
                ($key, $sub, $sub_key) = (undef, undef, undef);
            }
            next;
        }

        next unless defined $feat;

        # indent 2 — second-level field
        if ($indent == 2) {
            if ($stripped =~ /^([a-z_][a-z0-9_]*):\s*(.*)/) {
                $key = $1;
                my $val = $2;
                ($sub, $sub_key) = (undef, undef);
                $val =~ s/\s+#.*$//;  # strip inline comments
                $val =~ s/^\s+|\s+$//g;
                if ($val eq '' || $val eq '{}') {
                    $feat->{$key} = {};
                } elsif ($val eq '[]') {
                    $feat->{$key} = [];
                } else {
                    $feat->{$key} = $val;
                }
            }
            next;
        }

        # indent 4 — list item or nested key
        if ($indent == 4) {
            if ($stripped =~ /^- (.*)/) {
                my $val = $1;
                $val =~ s/\s+#.*$//;
                $val =~ s/^\s+|\s+$//g;
                if (defined $key) {
                    $feat->{$key} = [] unless ref $feat->{$key} eq 'ARRAY';
                    push @{$feat->{$key}}, $val;
                }
                next;
            }
            if ($stripped =~ /^([a-z_][a-z0-9_]*):\s*(.*)/) {
                $sub_key = $1;
                my $val = $2;
                $val =~ s/\s+#.*$//;
                $val =~ s/^\s+|\s+$//g;
                $feat->{$key} = {} unless ref $feat->{$key} eq 'HASH';
                $sub = $feat->{$key};
                $sub->{$sub_key} = ($val eq '' || $val eq '{}') ? {} : $val;
            }
            next;
        }

        # indent 6 — list item or key under patches sub-entry
        if ($indent == 6) {
            if ($stripped =~ /^- (.*)/) {
                my $val = $1;
                $val =~ s/\s+#.*$//;
                $val =~ s/^\s+|\s+$//g;
                if (defined $sub && defined $sub_key) {
                    $sub->{$sub_key} = [] unless ref $sub->{$sub_key} eq 'ARRAY';
                    if ($val =~ /^([a-z_]+):\s*(.*)/) {
                        my ($k, $v) = ($1, $2);
                        $v =~ s/^['"]|['"]$//g;
                        push @{$sub->{$sub_key}}, { $k => $v };
                    } else {
                        push @{$sub->{$sub_key}}, $val;
                    }
                }
                next;
            }
            if ($stripped =~ /^([a-z_][a-z0-9_]*):\s*(.*)/ && defined $sub && defined $sub_key) {
                my ($k, $v) = ($1, $2);
                $v =~ s/\s+#.*$//;
                $v =~ s/^['"]|['"]$//g;
                $v =~ s/^\s+|\s+$//g;
                $sub->{$sub_key} = {} unless ref $sub->{$sub_key} eq 'HASH';
                $sub->{$sub_key}{$k} = $v;
            }
            next;
        }

        # indent 8 — key-value inside replacements list-of-dicts
        if ($indent == 8) {
            if ($stripped =~ /^([a-z_]+):\s*(.*)/ && defined $sub && defined $sub_key) {
                my ($k, $v) = ($1, $2);
                $v =~ s/\s+#.*$//;
                $v =~ s/^['"]|['"]$//g;
                $v =~ s/^\s+|\s+$//g;
                my $lst = $sub->{$sub_key};
                if (ref $lst eq 'ARRAY' && @$lst && ref $lst->[-1] eq 'HASH') {
                    $lst->[-1]{$k} = $v;
                } else {
                    $sub->{$sub_key} = [] unless ref $lst eq 'ARRAY';
                    push @{$sub->{$sub_key}}, { $k => $v };
                }
            }
            next;
        }
    }
    return \%root;
}

# ── Accessors ─────────────────────────────────────────────────────────────────
sub get_array {
    my ($root, $feat_name, $key) = @_;
    my $feat = $root->{$feat_name} // {};
    my $val  = $feat->{$key} // [];
    return () unless defined $val;
    return @$val  if ref $val eq 'ARRAY';
    return ($val) if !ref $val && $val =~ /\S/;
    return ();
}

sub get_scalar {
    my ($root, $feat_name, $key) = @_;
    my $feat = $root->{$feat_name} // {};
    return $feat->{$key} // '';
}

sub get_patch {
    my ($root, $patch_name, $subkey) = @_;
    my $patches = $root->{patches} // {};
    my $p = $patches->{$patch_name} // {};
    if ($subkey =~ /^(path|action|backup)$/) {
        return $p->{$subkey} // '';
    }
    if ($subkey eq 'keep_services') {
        my @v = ref $p->{keep_services} eq 'ARRAY' ? @{$p->{keep_services}} : ();
        return join("\n", @v);
    }
    if ($subkey eq 'replacements') {
        my @r = ref $p->{replacements} eq 'ARRAY' ? @{$p->{replacements}} : ();
        my @out;
        for my $item (@r) {
            next unless ref $item eq 'HASH';
            push @out, ($item->{from}//'') . '|||' . ($item->{to}//'');
        }
        return join("\n", @out);
    }
    return '';
}

# ── Dump functions ─────────────────────────────────────────────────────────────
sub emit_ssv {
    my ($root, $mount, @features) = @_;
    my %seen;
    my $e = sub {
        my $rel = shift;
        $rel =~ s/^\s+|\s+$//g;
        return unless $rel;
        return if $seen{$rel}++;
        print(($mount ? "$mount/$rel" : "/$rel") . "\n");
    };
    for my $fn (@features) {
        $e->($_) for get_array($root, $fn, 'apps');
        $e->($_) for get_array($root, $fn, 'helpers');
        $e->($_) for get_array($root, $fn, 'xpc');
        $e->($_) for get_array($root, $fn, 'frameworks');
        $e->($_) for get_array($root, $fn, 'kexts');
        $e->($_) for get_array($root, $fn, 'services');
        $e->($_) for get_array($root, $fn, 'coreservices');
        $e->($_) for get_array($root, $fn, 'ssv_extra_paths');
        $e->("System/Library/PreferencePanes/$_")        for get_array($root, $fn, 'prefpanes');
        $e->("System/Library/Spotlight/$_")              for get_array($root, $fn, 'mdimporters');
        $e->("System/Library/CoreServices/Menu Extras/$_") for get_array($root, $fn, 'menu_extras');
        $e->("System/Library/AssetsV2/$_")               for get_array($root, $fn, 'assets');
        $e->("System/Library/LaunchAgents/$_.plist")     for get_array($root, $fn, 'launchagent_plists');
        $e->("System/Library/LaunchDaemons/$_.plist")    for get_array($root, $fn, 'launchdaemon_plists');
        for my $p (get_array($root, $fn, 'appex')) {
            $e->($p =~ /^System\// ? $p : "System/Library/ExtensionKit/Extensions/$p");
        }
        for my $p (get_array($root, $fn, 'input_methods')) {
            $e->($p =~ /^System\// ? $p : "System/Library/Input Methods/$p");
        }
        $e->("System/Library/CoreServices/ControlCenter.app/Contents/Resources/$_")
            for get_array($root, $fn, 'loctables');
    }
}

sub emit_agents {
    my ($root, @features) = @_;
    my %seen;
    for my $fn (@features) {
        for my $a (get_array($root, $fn, 'agents')) {
            my $label = $a =~ /^com\./ ? $a : "com.apple.$a";
            next if $seen{$label}++;
            print "$label\n";
        }
    }
}

sub emit_daemons {
    my ($root, @features) = @_;
    my %seen;
    for my $fn (@features) {
        for my $d (get_array($root, $fn, 'daemons')) {
            next if $seen{$d}++;
            print "$d\n";
        }
    }
}

sub emit_user_data {
    my ($root, $home, @features) = @_;
    my %seen;
    my $e = sub {
        my ($tag, $path) = @_;
        return if $seen{$path}++;
        print "$tag\t$path\n";
    };
    for my $fn (@features) {
        $e->('container',       "$home/Library/Containers/$_")       for get_array($root, $fn, 'user_containers');
        $e->('group_container', "$home/Library/Group Containers/$_") for get_array($root, $fn, 'user_group_containers');
        $e->('pref',            "$home/Library/Preferences/$_.plist") for get_array($root, $fn, 'user_prefs');
        $e->('cache',           "$home/Library/Caches/$_")           for get_array($root, $fn, 'user_caches');
    }
}

sub emit_pluginkit {
    my ($root, @features) = @_;
    my %seen;
    for my $fn (@features) {
        for my $v (get_array($root, $fn, 'pluginkit')) {
            next if $seen{$v}++;
            print "$v\n";
        }
    }
}

sub emit_frameworks {
    my ($root) = @_;
    my %seen;
    for my $fn (keys %$root) {
        next if $fn eq 'patches' || ref $root->{$fn} ne 'HASH';
        for my $fw (get_array($root, $fn, 'frameworks')) {
            $fw =~ s|/+$||;
            next if $seen{$fw}++;
            print "$fw\n";
        }
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
my ($manifest, $cmd, @rest) = @ARGV;
die "Usage: parser.pl <manifest> <cmd> [args]\n" unless $manifest && $cmd;

my $root = load($manifest);

if ($cmd eq 'list_features') {
    print "$_\n" for grep { $_ ne 'patches' } keys %$root;

} elsif ($cmd eq 'get_array' && @rest == 2) {
    print "$_\n" for get_array($root, $rest[0], $rest[1]);

} elsif ($cmd eq 'get_scalar' && @rest == 2) {
    print get_scalar($root, $rest[0], $rest[1]), "\n";

} elsif ($cmd eq 'list_patches') {
    my $patches = $root->{patches} // {};
    print "$_\n" for keys %$patches;

} elsif ($cmd eq 'get_patch' && @rest == 2) {
    print get_patch($root, $rest[0], $rest[1]), "\n";

} elsif ($cmd eq 'dump_ssv_paths' && @rest >= 1) {
    my $mount = shift @rest;
    emit_ssv($root, $mount, @rest);

} elsif ($cmd eq 'dump_agents' && @rest >= 1) {
    emit_agents($root, @rest);

} elsif ($cmd eq 'dump_daemons' && @rest >= 1) {
    emit_daemons($root, @rest);

} elsif ($cmd eq 'dump_user_data' && @rest >= 2) {
    my $home = shift @rest;
    emit_user_data($root, $home, @rest);

} elsif ($cmd eq 'dump_pluginkit' && @rest >= 1) {
    emit_pluginkit($root, @rest);

} elsif ($cmd eq 'dump_frameworks') {
    emit_frameworks($root);

} else {
    die "Unknown command: $cmd\n";
}
PLEOF
chmod +x "$PARSER_PY"

# ---------------------------------------------------------------------------
# Cleanup trap — remove all temp files on any exit (normal or error)
# ---------------------------------------------------------------------------
_CLEANUP_FILES=("$PARSER_PY")
_cleanup() {
    rm -f "${_CLEANUP_FILES[@]}" 2>/dev/null || true
    rm -f /tmp/verify_*.XXXXXX /tmp/.verify_otool.* 2>/dev/null || true
    rm -f /tmp/debloat_paths_$$ /tmp/debloat_tcclist_$$.plist /tmp/debloat_seclist_$$.plist 2>/dev/null || true
    rm -f /tmp/debloat_bless_err_$$ /tmp/debloat_dock_ids.$$ /tmp/debloat_rm_err_$$ 2>/dev/null || true
}
trap _cleanup EXIT

py() { perl "$PARSER_PY" "$MANIFEST" "$@"; }

# ---------------------------------------------------------------------------
# Snapshot metadata — written to snapshot-metadata.tsv in the script dir.
# Columns (tab-separated): uuid | date | type | features | macos_version
# Called after every bless event so restore.sh can display enriched info.
# Idempotent: silently skips if the UUID is already present in the file.
# ---------------------------------------------------------------------------
_write_snap_meta() {
    local uuid="$1" type="$2" features="$3"
    [ -z "$uuid" ] && return
    local tsv="$SCRIPT_DIR/snapshot-metadata.tsv"
    local date_str macos_ver
    date_str=$(date '+%Y-%m-%d %H:%M:%S')
    macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
    # Create file with header if it does not exist yet
    if [ ! -f "$tsv" ]; then
        printf 'uuid\tdate\ttype\tfeatures\tmacos_version\n' > "$tsv"
    fi
    # Skip duplicate entries
    grep -qF "$uuid" "$tsv" 2>/dev/null && return
    printf '%s\t%s\t%s\t%s\t%s\n' "$uuid" "$date_str" "$type" "$features" "$macos_ver" >> "$tsv"
    log "Metadata written → snapshot-metadata.tsv  ($type  $uuid)"
}

# ---------------------------------------------------------------------------
# List features and exit if requested
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = true ]; then
    header "FEATURES IN MANIFEST"
    py list_features
    exit 0
fi

# ---------------------------------------------------------------------------
# Build feature list (needed by --verify and execution phases alike)
# ---------------------------------------------------------------------------
ALL_FEATURES=()
while IFS= read -r f; do
    ALL_FEATURES+=("$f")
done < <(py list_features || { err "Parser failed on list_features — check manifest.yaml syntax"; exit 1; })

FEATURES=()
if [ -n "$FEATURE_FILTER" ]; then
    IFS=',' read -ra FEATURES <<< "$FEATURE_FILTER"
else
    FEATURES=("${ALL_FEATURES[@]}")
fi

# Remove skipped features
SKIP_LIST=()
if [ -n "$SKIP_FILTER" ]; then
    IFS=',' read -ra SKIP_LIST <<< "$SKIP_FILTER"
fi
FINAL_FEATURES=()
for f in "${FEATURES[@]}"; do
    skip=false
    for s in "${SKIP_LIST[@]+"${SKIP_LIST[@]}"}"; do
        [ "$f" = "$s" ] && skip=true && break
    done
    $skip || FINAL_FEATURES+=("$f")
done

log "Features to process: ${#FINAL_FEATURES[@]}"
for f in "${FINAL_FEATURES[@]}"; do log "  - $f"; done

# ===========================================================================
# PHASE V: VERIFY — read-only dependency audit using Xcode tools
# Invoked with --verify. Never modifies anything. Exits non-zero if any
# UNSAFE entries are found (framework linked by a kept binary).
#
# Tools used:
#   otool -L          — Mach-O load command dylib scanner
#   kextstat          — kernel extension load state
#   launchctl print-disabled — agent/daemon enable state
#   plutil -lint      — plist structural validity
#   pluginkit -m      — extension registration state
# ===========================================================================
run_verify() {
    header "PHASE V: MANIFEST VERIFICATION (read-only)"

    # -----------------------------------------------------------------------
    # Check required tools
    # -----------------------------------------------------------------------
    local OTOOL PLUTIL KEXTSTAT PLUGINKIT LAUNCHCTL
    OTOOL=$(command -v otool 2>/dev/null)
    PLUTIL=$(command -v plutil 2>/dev/null)
    KEXTSTAT=$(command -v kextstat 2>/dev/null)
    PLUGINKIT=$(command -v pluginkit 2>/dev/null)
    LAUNCHCTL=$(command -v launchctl 2>/dev/null)

    [ -z "$OTOOL" ]    && { err "otool not found — install Xcode CLT: xcode-select --install"; exit 1; }
    [ -z "$PLUTIL" ]   && { err "plutil not found"; exit 1; }
    [ -z "$KEXTSTAT" ] && { err "kextstat not found"; exit 1; }
    [ -z "$PLUGINKIT" ]&& { err "pluginkit not found"; exit 1; }
    [ -z "$LAUNCHCTL" ]&& { err "launchctl not found"; exit 1; }

    log "Tools: otool=$OTOOL plutil=$PLUTIL kextstat=$KEXTSTAT"
    log ""

    # -----------------------------------------------------------------------
    # Step V1: Build recursive otool dependency tree for all KEPT binaries.
    # These are the binaries that will remain on the system after debloat.
    # Any framework linked (directly or transitively) by ANY kept binary
    # must NOT be deleted from the SSV.
    # -----------------------------------------------------------------------
    header "V1: Recursive otool scan of kept binaries"

    local KEPT_BINARIES=(
        "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
        "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"
        "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer"
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        "/System/Library/CoreServices/WindowManager.app/Contents/MacOS/WindowManager"
        "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
        "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent"
        "/System/Applications/System Settings.app/Contents/MacOS/System Settings"
        "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
        "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor"
        "/System/Applications/Utilities/Disk Utility.app/Contents/MacOS/Disk Utility"
        "/System/Applications/Utilities/Console.app/Contents/MacOS/Console"
        "/System/Applications/Calculator.app/Contents/MacOS/Calculator"
        "/System/Applications/Preview.app/Contents/MacOS/Preview"
        "/System/Applications/Utilities/Screenshot.app/Contents/MacOS/Screenshot"
        "/System/Applications/Utilities/Audio MIDI Setup.app/Contents/MacOS/Audio MIDI Setup"
        "/System/Applications/Utilities/Bluetooth File Exchange.app/Contents/MacOS/Bluetooth File Exchange"
        "/System/Applications/Utilities/Digital Color Meter.app/Contents/MacOS/Digital Color Meter"
        "/System/Applications/Utilities/System Information.app/Contents/MacOS/System Information"
        "/System/Library/CoreServices/VoiceOver.app/Contents/MacOS/VoiceOver"
        "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"
        "/usr/bin/mdfind"
    )

    # Python script: recursive otool walk, outputs one normalised framework
    # dir per line. Uses stdlib only — works without PyYAML.
    local OTOOL_WALKER
    OTOOL_WALKER=$(mktemp /tmp/.verify_otool.XXXXXX.py)
    cat > "$OTOOL_WALKER" << 'PYEOF'
#!/usr/bin/env python3
import subprocess, sys, os, re
from collections import deque

VISITED = set()
RESULTS = set()
DEPTH   = 8

def normalise(p):
    p = re.sub(r'/Versions/[^/]+/', '/', p)
    p = p.strip().lstrip('/')
    m = re.match(r'(.*?\.framework)', p)
    return m.group(1) if m else p

def deps(binary):
    try:
        out = subprocess.check_output(
            ['otool', '-L', binary],
            stderr=subprocess.DEVNULL, timeout=10
        ).decode('utf-8', errors='replace')
    except Exception:
        return []
    result = []
    for line in out.splitlines()[1:]:
        path = line.strip().split(' (')[0].strip()
        if path and path != binary:
            result.append(path)
    return result

def walk(start):
    q = deque([(start, 0)])
    while q:
        binary, depth = q.popleft()
        if binary in VISITED or depth > DEPTH:
            continue
        VISITED.add(binary)
        if not os.path.exists(binary):
            continue
        for dep in deps(binary):
            norm = normalise(dep)
            RESULTS.add(norm)
            if dep not in VISITED:
                q.append((dep, depth + 1))

for b in sys.argv[1:]:
    walk(b)

for r in sorted(RESULTS):
    if 'Library/' in r:
        print(r)
PYEOF
    chmod +x "$OTOOL_WALKER"

    log "Scanning ${#KEPT_BINARIES[@]} kept binaries (depth 8, may take ~30s)..."
    local KEPT_DEPS_FILE
    KEPT_DEPS_FILE=$(mktemp /tmp/verify_kept_deps.XXXXXX)
    python3 "$OTOOL_WALKER" "${KEPT_BINARIES[@]}" 2>/dev/null | sort -u > "$KEPT_DEPS_FILE"
    local DEP_COUNT
    DEP_COUNT=$(wc -l < "$KEPT_DEPS_FILE" | tr -d ' ')
    log "Unique framework paths linked by kept binaries: $DEP_COUNT"

    # -----------------------------------------------------------------------
    # Step V2: Cross-check every framework in the manifest against kept deps.
    # -----------------------------------------------------------------------
    header "V2: Framework safety check (manifest vs otool deps)"

    local V_UNSAFE=0
    local V_SAFE=0
    local V_MISSING=0
    local UNSAFE_LIST=()

    # Collect all planned-delete frameworks from manifest
    local ALL_FW_FILE
    ALL_FW_FILE=$(mktemp /tmp/verify_manifest_fw.XXXXXX)
    # Use the manifest parser (stdlib, no PyYAML) to extract frameworks
    python3 "$PARSER_PY" "$MANIFEST" dump_frameworks > "$ALL_FW_FILE"

    while IFS= read -r fw_path; do
        [ -z "$fw_path" ] && continue
        # Normalise: strip leading slash, strip trailing version component
        local fw_norm
        fw_norm=$(echo "$fw_path" | sed 's|^/||; s|/Versions/[^/]*/|/|g; s|/$||')
        # Extract framework dir (up to .framework)
        local fw_dir
        fw_dir=$(echo "$fw_norm" | sed 's|\(.*\.framework\).*|\1|')

        # Check 1: does it exist on disk?
        if [ ! -e "/$fw_dir" ]; then
            printf "  [MISSING]  %-80s (not on disk)\n" "$fw_dir"
            V_MISSING=$((V_MISSING + 1))
            continue
        fi

        # Check 2: is it in the kept-binary dep chain?
        if grep -qF "$fw_dir" "$KEPT_DEPS_FILE" 2>/dev/null; then
            # Find which kept binary links it
            local linked_by
            linked_by=$(python3 "$OTOOL_WALKER" "${KEPT_BINARIES[@]}" 2>/dev/null \
                | grep -F "$fw_dir" | head -1 || echo "see otool scan")
            printf "  [UNSAFE]   %-70s  ← linked by kept binary\n" "$fw_dir"
            V_UNSAFE=$((V_UNSAFE + 1))
            UNSAFE_LIST+=("$fw_dir")
        else
            printf "  [SAFE]     %s\n" "$fw_dir"
            V_SAFE=$((V_SAFE + 1))
        fi
    done < "$ALL_FW_FILE"

    log ""
    log "Framework check: SAFE=$V_SAFE  UNSAFE=$V_UNSAFE  MISSING=$V_MISSING"

    # -----------------------------------------------------------------------
    # Step V3: kext load-state check
    # -----------------------------------------------------------------------
    header "V3: Kext load-state check"

    local V_KEXT_LOADED=0
    local V_KEXT_UNLOADED=0

    # V3: kext check — single call to get all kexts across features
    local KEXTSTAT_OUT
    KEXTSTAT_OUT=$("$KEXTSTAT" 2>/dev/null)
    while IFS= read -r kext_path; do
        [ -z "$kext_path" ] && continue
        local kext_name
        kext_name=$(basename "$kext_path" .kext)
        if echo "$KEXTSTAT_OUT" | grep -qF "$kext_name"; then
            printf "  [LOADED]   %s  ← unexpectedly loaded — check before deleting\n" "$kext_name"
            V_KEXT_LOADED=$((V_KEXT_LOADED + 1))
        else
            printf "  [UNLOADED] %s\n" "$kext_name"
            V_KEXT_UNLOADED=$((V_KEXT_UNLOADED + 1))
        fi
    done < <(python3 "$PARSER_PY" "$MANIFEST" dump_ssv_paths "" "${FINAL_FEATURES[@]}" \
        | grep '\.kext$')

    log "Kext check: UNLOADED=$V_KEXT_UNLOADED  LOADED(unexpected)=$V_KEXT_LOADED"

    # -----------------------------------------------------------------------
    # Step V4: LaunchAgent / LaunchDaemon plist validation
    # For each plist in launchagent_plists / launchdaemon_plists:
    #   - plutil -lint: structural validity
    #   - plutil -extract Program: confirm program binary exists
    #   - plutil -extract MachServices: list XPC services it advertises
    # -----------------------------------------------------------------------
    header "V4: LaunchAgent/Daemon plist validation"

    local V_PLIST_OK=0
    local V_PLIST_BAD=0
    local V_PLIST_MISSING=0

    _check_plist() {
        local plist_path="$1"
        local label
        label=$(basename "$plist_path" .plist)

        if [ ! -f "$plist_path" ]; then
            printf "  [MISSING]  %s\n" "$label"
            V_PLIST_MISSING=$((V_PLIST_MISSING + 1))
            return
        fi

        # Lint
        if ! "$PLUTIL" -lint "$plist_path" >/dev/null 2>&1; then
            printf "  [INVALID]  %s  ← plutil lint failed\n" "$label"
            V_PLIST_BAD=$((V_PLIST_BAD + 1))
            return
        fi

        # Extract Program binary
        local prog
        prog=$("$PLUTIL" -extract ProgramArguments.0 raw "$plist_path" 2>/dev/null \
            || "$PLUTIL" -extract Program raw "$plist_path" 2>/dev/null \
            || echo "N/A")

        # Extract MachServices keys (XPC services this plist advertises)
        local mach
        mach=$("$PLUTIL" -extract MachServices raw "$plist_path" 2>/dev/null || echo "none")

        local prog_state="exists"
        [ "$prog" != "N/A" ] && [ ! -e "$prog" ] && prog_state="MISSING_BINARY"

        printf "  [OK]       %-55s  prog=%-50s  mach=%s\n" \
            "$label" "$prog ($prog_state)" "$mach"
        V_PLIST_OK=$((V_PLIST_OK + 1))
    }

    # V4 plist check — single call for all agent/daemon plists
    local ALL_PLISTS_FILE
    ALL_PLISTS_FILE=$(mktemp /tmp/verify_plists.XXXXXX)
    python3 "$PARSER_PY" "$MANIFEST" dump_ssv_paths "" "${FINAL_FEATURES[@]}" \
        | grep -E 'LaunchAgents/|LaunchDaemons/' > "$ALL_PLISTS_FILE"

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        _check_plist "/$rel_path"
    done < "$ALL_PLISTS_FILE"
    rm -f "$ALL_PLISTS_FILE"

    log "Plist check: OK=$V_PLIST_OK  INVALID=$V_PLIST_BAD  MISSING=$V_PLIST_MISSING"

    # -----------------------------------------------------------------------
    # Step V5: Agent / Daemon enable-state check via launchctl
    # Reports current state: enabled / disabled / not-registered
    # -----------------------------------------------------------------------
    header "V5: Agent/Daemon enable-state (launchctl print-disabled)"

    local UID_V="${SUDO_UID:-$(id -u)}"
    local AGENT_STATE_FILE DAEMON_STATE_FILE
    AGENT_STATE_FILE=$(mktemp /tmp/verify_agents.XXXXXX)
    DAEMON_STATE_FILE=$(mktemp /tmp/verify_daemons.XXXXXX)
    "$LAUNCHCTL" print-disabled "gui/$UID_V"  2>/dev/null > "$AGENT_STATE_FILE"
    "$LAUNCHCTL" print-disabled "system"       2>/dev/null > "$DAEMON_STATE_FILE"

    local V_AGENT_ENABLED=0 V_AGENT_DISABLED=0 V_AGENT_UNKNOWN=0
    local V_DAEMON_ENABLED=0 V_DAEMON_DISABLED=0 V_DAEMON_UNKNOWN=0

    # V5 agent/daemon state — single call each
    while IFS= read -r label; do
        [ -z "$label" ] && continue
        if grep -qF "\"$label\" => disabled" "$AGENT_STATE_FILE" 2>/dev/null; then
            printf "  [DISABLED] agent  %s\n" "$label"
            V_AGENT_DISABLED=$((V_AGENT_DISABLED + 1))
        elif grep -qF "\"$label\" => enabled" "$AGENT_STATE_FILE" 2>/dev/null; then
            printf "  [ENABLED]  agent  %s  ← will be disabled\n" "$label"
            V_AGENT_ENABLED=$((V_AGENT_ENABLED + 1))
        else
            printf "  [UNKNOWN]  agent  %s  ← not in launchctl registry\n" "$label"
            V_AGENT_UNKNOWN=$((V_AGENT_UNKNOWN + 1))
        fi
    done < <(python3 "$PARSER_PY" "$MANIFEST" dump_agents "${FINAL_FEATURES[@]}")

    while IFS= read -r label; do
        [ -z "$label" ] && continue
        if grep -qF "\"$label\" => disabled" "$DAEMON_STATE_FILE" 2>/dev/null; then
            printf "  [DISABLED] daemon %s\n" "$label"
            V_DAEMON_DISABLED=$((V_DAEMON_DISABLED + 1))
        elif grep -qF "\"$label\" => enabled" "$DAEMON_STATE_FILE" 2>/dev/null; then
            printf "  [ENABLED]  daemon %s  ← will be disabled\n" "$label"
            V_DAEMON_ENABLED=$((V_DAEMON_ENABLED + 1))
        else
            printf "  [UNKNOWN]  daemon %s  ← not in launchctl registry\n" "$label"
            V_DAEMON_UNKNOWN=$((V_DAEMON_UNKNOWN + 1))
        fi
    done < <(python3 "$PARSER_PY" "$MANIFEST" dump_daemons "${FINAL_FEATURES[@]}")

    log "Agent state:  ENABLED=$V_AGENT_ENABLED  DISABLED=$V_AGENT_DISABLED  UNKNOWN=$V_AGENT_UNKNOWN"
    log "Daemon state: ENABLED=$V_DAEMON_ENABLED  DISABLED=$V_DAEMON_DISABLED  UNKNOWN=$V_DAEMON_UNKNOWN"

    # -----------------------------------------------------------------------
    # Step V6: SSV path existence check
    # For every non-framework SSV path: report PRESENT / MISSING
    # -----------------------------------------------------------------------
    header "V6: SSV path existence check"

    local V_PRESENT=0 V_ABSENT=0
    # V6: SSV path existence — single call
    while IFS= read -r full_path; do
        [ -z "$full_path" ] && continue
        if [ -e "$full_path" ]; then
            printf "  [PRESENT]  %s\n" "$full_path"
            V_PRESENT=$((V_PRESENT + 1))
        else
            printf "  [ABSENT]   %s\n" "$full_path"
            V_ABSENT=$((V_ABSENT + 1))
        fi
    done < <(python3 "$PARSER_PY" "$MANIFEST" dump_ssv_paths "" "${FINAL_FEATURES[@]}")

    log "SSV path check: PRESENT=$V_PRESENT  ABSENT(already gone)=$V_ABSENT"

    # -----------------------------------------------------------------------
    # Step V7: User data existence check
    # -----------------------------------------------------------------------
    header "V7: User data existence check"

    local USER_HOME_V
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME_V=$(dscl . -read /Users/"$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        [ -z "$USER_HOME_V" ] && USER_HOME_V=$(eval echo "~$SUDO_USER")
    else
        USER_HOME_V="$HOME"
    fi

    local V_USER_PRESENT=0 V_USER_ABSENT=0
    # V7: single call for all user data paths
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local upath="${line#*	}"   # strip tag\t prefix
        if [ -e "$upath" ]; then
            printf "  [PRESENT]  %s\n" "$upath"; V_USER_PRESENT=$((V_USER_PRESENT+1))
        else
            printf "  [ABSENT]   %s\n" "$upath"; V_USER_ABSENT=$((V_USER_ABSENT+1))
        fi
    done < <(python3 "$PARSER_PY" "$MANIFEST" dump_user_data "$USER_HOME_V" "${FINAL_FEATURES[@]}")

    log "User data: PRESENT=$V_USER_PRESENT  ABSENT(already gone)=$V_USER_ABSENT"

    # -----------------------------------------------------------------------
    # VERIFY SUMMARY
    # -----------------------------------------------------------------------
    header "VERIFY SUMMARY"

    log "V1 Kept-binary dep scan:  $DEP_COUNT unique framework paths"
    log "V2 Framework safety:      SAFE=$V_SAFE  UNSAFE=$V_UNSAFE  MISSING=$V_MISSING"
    log "V3 Kext load state:       UNLOADED=$V_KEXT_UNLOADED  LOADED(unexpected)=$V_KEXT_LOADED"
    log "V4 Plist validity:        OK=$V_PLIST_OK  INVALID=$V_PLIST_BAD  MISSING=$V_PLIST_MISSING"
    log "V5 Agent enable state:    ENABLED=$V_AGENT_ENABLED  DISABLED=$V_AGENT_DISABLED  UNKNOWN=$V_AGENT_UNKNOWN"
    log "V5 Daemon enable state:   ENABLED=$V_DAEMON_ENABLED  DISABLED=$V_DAEMON_DISABLED  UNKNOWN=$V_DAEMON_UNKNOWN"
    log "V6 SSV paths:             PRESENT=$V_PRESENT  ABSENT=$V_ABSENT"
    log "V7 User data:             PRESENT=$V_USER_PRESENT  ABSENT=$V_USER_ABSENT"
    echo ""

    if [ "${#UNSAFE_LIST[@]}" -gt 0 ]; then
        err "═══════════════════════════════════════════════════════════"
        err "  VERIFY FAILED — ${#UNSAFE_LIST[@]} UNSAFE framework(s) found."
        err "  These are linked by kept binaries and must be removed"
        err "  from the manifest before execution:"
        for u in "${UNSAFE_LIST[@]}"; do
            err "    UNSAFE: $u"
        done
        err "═══════════════════════════════════════════════════════════"
        # Cleanup
        rm -f "$KEPT_DEPS_FILE" "$ALL_FW_FILE" "$AGENT_STATE_FILE" \
              "$DAEMON_STATE_FILE" "$OTOOL_WALKER"
        exit 1
    else
        ok "═══════════════════════════════════════════════════════════"
        ok "  VERIFY PASSED — no unsafe framework deletions detected."
        ok "  Manifest is safe to execute."
        ok "═══════════════════════════════════════════════════════════"
    fi

    # Cleanup temp files
    rm -f "$KEPT_DEPS_FILE" "$ALL_FW_FILE" "$AGENT_STATE_FILE" \
          "$DAEMON_STATE_FILE" "$OTOOL_WALKER"
}


if [ "$AGENTS_ONLY" = false ] && [ "$USER_ONLY" = false ]; then
    header "PHASE A: PRE-MOUNT PREPARATION"

    # -- Detect system volume device --
    # When booted from a sealed SSV snapshot, "/" reports disk3s1s1 (the snapshot
    # slice).  Strip the trailing snapshot suffix (s\d+) once to get the volume
    # device (disk3s1), which is what mount_apfs and bless need.
    SNAP_DEV=$(diskutil info / 2>/dev/null | awk '/[[:space:]]Device Identifier:/{print $NF; exit}')
    [ -z "$SNAP_DEV" ] && SNAP_DEV=$(mount | awk '$3 == "/" {gsub("/dev/",""); print $1; exit}')
    # Strip one trailing snapshot suffix (e.g. disk3s1s1 → disk3s1)
    BASE_DEVICE="/dev/$(echo "$SNAP_DEV" | sed 's/s[0-9][0-9]*$//')"

    log "Boot device:        /dev/$SNAP_DEV"
    log "Base system volume: $BASE_DEVICE"

    if ! echo "$BASE_DEVICE" | grep -qE "^/dev/disk[0-9]+s[0-9]+$"; then
        err "Could not determine system volume device: $BASE_DEVICE"
        exit 1
    fi

    # -- Detect Preboot volume device --
    # bless writes boot metadata into the Preboot volume. If it is not mounted
    # when bless runs, you get "No valid group or volume UUID folder" errors.
    # Find the Preboot volume on the same APFS container as the system volume.
    CONTAINER=$(echo "$BASE_DEVICE" | sed 's|/dev/||; s|s[0-9]*$||')  # e.g. disk3
    PREBOOT_DEV=$(diskutil list "$CONTAINER" 2>/dev/null \
        | awk '/Preboot/{print "/dev/"$NF; exit}')
    [ -z "$PREBOOT_DEV" ] && PREBOOT_DEV=$(diskutil list 2>/dev/null \
        | awk '/Preboot/{print "/dev/"$NF; exit}')
    PREBOOT_MOUNT="/System/Volumes/Preboot"

    log "Preboot volume:     ${PREBOOT_DEV:-(not detected)}"

    # -- Check SSV already modified --
    if [ ! -d "/System/Applications/News.app" ] && [ "$DRY_RUN" = false ]; then
        warn "News.app absent — SSV already modified. Re-running will re-delete any remaining paths."
    fi

    # -- Record existing bless snapshots BEFORE mount --
    log "[A1] Recording pre-existing bless snapshots..."
    PREV_BLESS_SNAPS=$(diskutil apfs listSnapshots "$SNAP_DEV" \
        | awk '/^\+-- /{uuid=$NF} /com\.apple\.bless\./{print uuid}')
    # Use awk to count lines — avoids grep -c which outputs "0\n0" when count=0
    # (grep -c exits 1 on zero matches, triggering the || fallback, doubling output)
    PREV_SNAP_COUNT=$(printf '%s' "$PREV_BLESS_SNAPS" | awk 'NF{c++} END{print c+0}')
    log "Existing bless snapshots: $PREV_SNAP_COUNT"

    # -- Build path list --
    log "[A2] Building SSV deletion path list..."
    PATHS_FILE="/tmp/debloat_paths_$$"
    > "$PATHS_FILE"
    COUNT_TOTAL=0
    COUNT_EXISTS=0

    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        rel_path="${rel_path#/}"  # dump_ssv_paths emits absolute paths; strip leading /
        COUNT_TOTAL=$((COUNT_TOTAL + 1))
        if [ -e "/$rel_path" ]; then
            printf '%s\0' "$MOUNT_POINT/$rel_path" >> "$PATHS_FILE"
            COUNT_EXISTS=$((COUNT_EXISTS + 1))
        fi
    done < <(perl "$PARSER_PY" "$MANIFEST" dump_ssv_paths "" "${FINAL_FEATURES[@]}")

    log "Total paths in manifest:  $COUNT_TOTAL"
    log "Paths that exist on /:    $COUNT_EXISTS"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would delete $COUNT_EXISTS paths from SSV. Listing:"
        while IFS= read -r -d '' p; do
            echo "    DEL: $p"
        done < "$PATHS_FILE"
    fi

    # -- Pre-generate TCC plist --
    log "[A3] Generating TCC/Section plists..."
    TCC_PLIST_FILE="/tmp/debloat_tcclist_$$.plist"
    SEC_PLIST_FILE="/tmp/debloat_seclist_$$.plist"

    # TCCServiceList: keep only the entries that are safe/required
    # Full rewrite — keeps Location, BT, LocalNetwork, Mic, Camera, FDA, Accessibility,
    # Input Monitoring, Screen Recording, Passkey, Automation, Dev Tools, Pasteboard,
    # Analytics, Advertising
    cat > "$TCC_PLIST_FILE" << 'TCCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict><key>serviceClass</key><string>PrivacyLocationService</string></dict>
	<dict>
		<key>requiresAdmin</key><true/>
		<key>revealElementKeyName</key><string>Privacy_Bluetooth</string>
		<key>serviceIcon-shared</key><string>com.apple.graphic-icon.bluetooth</string>
		<key>serviceName</key><string>BLUETOOTH</string>
		<key>supportsAddDeleteAction</key><true/>
		<key>tcc</key><string>kTCCServiceBluetoothAlways</string>
	</dict>
	<dict><key>serviceClass</key><string>PrivacyLocalNetworkService</string></dict>
	<dict><key>serviceClass</key><string>TCCServiceMicrophone</string></dict>
	<dict><key>serviceClass</key><string>TCCServiceCamera</string></dict>
	<dict><key>serviceClass</key><string>TCCServiceSystemPolicyAllFiles</string></dict>
	<dict>
		<key>requiresAdmin</key><true/>
		<key>revealElementKeyName</key><string>Privacy_AllFiles</string>
		<key>serviceIcon-shared</key><string>com.apple.graphic-icon.internal-drive</string>
		<key>serviceName</key><string>ALL_FILES</string>
		<key>supportsAddDeleteAction</key><true/>
		<key>tcc</key><string>kTCCServiceSystemPolicyAllFiles</string>
	</dict>
	<dict><key>serviceClass</key><string>TCCServiceAccessibility</string></dict>
	<dict>
		<key>requiresAdmin</key><true/>
		<key>revealElementKeyName</key><string>Privacy_ListenEvent</string>
		<key>serviceIcon-shared</key><string>com.apple.graphic-icon.input-monitoring</string>
		<key>serviceName</key><string>LISTEN_EVENT</string>
		<key>supportsAddDeleteAction</key><true/>
		<key>tcc</key><string>kTCCServiceListenEvent</string>
	</dict>
	<dict><key>serviceClass</key><string>PrivacyRecordingService</string></dict>
	<dict>
		<key>revealElementKeyName</key><string>Privacy_PasskeyAccess</string>
		<key>serviceIcon-shared</key><string>com.apple.graphic-icon.passkey</string>
		<key>serviceName</key><string>WEB_BROWSER_PASSKEY_ACCESS</string>
		<key>tcc</key><string>kTCCServiceWebBrowserPublicKeyCredential</string>
	</dict>
	<dict><key>serviceClass</key><string>TCCServiceAutomation</string></dict>
	<dict><key>serviceClass</key><string>TCCServiceDeveloperTools</string></dict>
	<dict><key>serviceClass</key><string>PrivacyPasteboardService</string></dict>
	<dict><key>serviceClass</key><string>PrivacyAnalyticsService</string></dict>
	<dict><key>serviceClass</key><string>PrivacyAdvertisingService</string></dict>
</array>
</plist>
TCCEOF

    cat > "$SEC_PLIST_FILE" << 'SECEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>locationServicesSection</key>
	<dict><key>LOCATION_SERVICES</key><string></string></dict>
	<key>subtitledServicesSection</key>
	<dict>
		<key>ALL_FILES</key><string></string>
		<key>FILE_ACCESS_COMBINED</key><string></string>
		<key>WEB_BROWSER_PASSKEY_ACCESS</key><string></string>
	</dict>
</dict>
</plist>
SECEOF

    plutil -lint "$TCC_PLIST_FILE" >/dev/null 2>&1 \
        && log "TCCServiceList plist: valid" \
        || { err "TCCServiceList plist failed lint — aborting"; exit 1; }
    plutil -lint "$SEC_PLIST_FILE" >/dev/null 2>&1 \
        && log "SectionServiceList plist: valid" \
        || { err "SectionServiceList plist failed lint — aborting"; exit 1; }

    log "Pre-mount preparation complete."
    log "SSV paths to delete: $COUNT_EXISTS"

    # -- [A4] Rolling restore snapshot ------------------------------------------
    # Create a named snapshot of the CURRENT SSV state BEFORE any modifications.
    # This gives a one-command boot restore if the run bricks the machine.
    # Policy: keep exactly ONE debloat.restore.* snapshot at all times.
    #   - If one already exists → keep it (it's the oldest known-good state).
    #   - If none exists → create one now from the current live SSV.
    # Phase C will NEVER delete debloat.restore.* snapshots.
    # ─────────────────────────────────────────────────────────────────────────
    RESTORE_SNAP_NAME=""
    RESTORE_SNAP_UUID=""
    if [ "$DRY_RUN" = false ]; then
        log "[A4] Managing rolling restore snapshot..."
        # Check for existing restore snapshot
        EXISTING_RESTORE=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null             | awk '/com\.apple\.debloat\.restore/{found=1} found && /XID:/{print; exit}')
        EXISTING_RESTORE_UUID=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null             | awk '/^\+-- /{uuid=$NF} /com\.apple\.debloat\.restore/{print uuid; exit}')

        if [ -n "$EXISTING_RESTORE_UUID" ]; then
            RESTORE_SNAP_UUID="$EXISTING_RESTORE_UUID"
            log "Existing restore snapshot found: $RESTORE_SNAP_UUID"
            log "  (keeping — it represents the last known-good pre-debloat state)"
            _write_snap_meta "$RESTORE_SNAP_UUID" "restore" ""
        else
            # No restore snapshot exists — create one via bless --create-snapshot.
            # macOS 26 removed "diskutil apfs createSnapshot".
            # If BASE_DEVICE is already mounted (macOS keeps /dev/disk3s3 live at
            # /System/Volumes/Update/mnt1), use that mount point directly.
            # Otherwise mount it ourselves, snap, then unmount.
            log "Creating restore snapshot (via bless --create-snapshot)..."
            SNAP_MOUNT=""
            _SNAP_MOUNTED_BY_US=false

            # Check if BASE_DEVICE is already mounted somewhere writable
            # Use diskutil info — awk '$3' breaks on paths with spaces like "/Volumes/Macintosh HD"
            SNAP_MOUNT=$(diskutil info "$BASE_DEVICE" 2>/dev/null \
                | awk '/Mount Point:/{sub(/.*Mount Point:[[:space:]]*/, ""); print; exit}')

            if [ -z "$SNAP_MOUNT" ]; then
                # Not mounted — use diskutil mount (works where mount_apfs fails)
                mkdir -p "$MOUNT_POINT" 2>/dev/null || true
                _SNAP_ERR=$(diskutil mount -mountPoint "$MOUNT_POINT" "$BASE_DEVICE" 2>&1)
                if [ $? -ne 0 ]; then
                    # Fallback to mount_apfs
                    _SNAP_ERR2=$(mount_apfs -o nobrowse "$BASE_DEVICE" "$MOUNT_POINT" 2>&1)
                    if [ $? -ne 0 ]; then
                        err "Could not mount $BASE_DEVICE for snapshot: $_SNAP_ERR / $_SNAP_ERR2"
                        SNAP_MOUNT=""
                    else
                        SNAP_MOUNT="$MOUNT_POINT"
                        _SNAP_MOUNTED_BY_US=true
                    fi
                else
                    log "  $_SNAP_ERR"
                    SNAP_MOUNT="$MOUNT_POINT"
                    _SNAP_MOUNTED_BY_US=true
                fi
            else
                log "  Using existing mount: $BASE_DEVICE → $SNAP_MOUNT"
            fi

            if [ -n "$SNAP_MOUNT" ]; then
                _SNAP_ERR=$(bless --mount "$SNAP_MOUNT" --create-snapshot 2>&1)
                _SNAP_RET=$?
                if [ "$_SNAP_MOUNTED_BY_US" = true ]; then
                    _UNMOUNT_OUT=$(diskutil unmount "$SNAP_MOUNT" 2>&1) || true
                    log "  $_UNMOUNT_OUT"
                fi
                if [ $_SNAP_RET -eq 0 ]; then
                    # bless creates a com.apple.bless.* snapshot — find the newest one
                    RESTORE_SNAP_UUID=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null \
                        | awk '/^\+-- /{uuid=$NF} /com\.apple\.bless\./{last=uuid} END{print last}')
                    ok "Restore snapshot created: $RESTORE_SNAP_UUID"
                    _write_snap_meta "$RESTORE_SNAP_UUID" "restore" ""
                else
                    err "Could not create restore snapshot: $_SNAP_ERR"
                    warn "Free space:"; df -h / 2>/dev/null | tail -1
                    warn "Existing snapshots:"
                    diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null | grep -E "Name:|XID:" | head -10
                fi
            fi
        fi

        # Always find os.update snapshot as ultimate fallback
        OS_UPDATE_UUID=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null \
            | awk '/^\+-- /{uuid=$NF} /com\.apple\.os\.update/{print uuid; exit}')

        # Write RESTORE-CMD.txt BEFORE Phase B — must exist before any deletion
        RESTORE_CMD_FILE="${LOG%.log}-RESTORE-CMD.txt"
        {
            echo "# DEBLOAT RESTORE COMMAND — $(date)"
            echo "# ╔══════════════════════════════════════════════════════════════╗"
            echo "# ║  MUST BE RUN FROM RECOVERY TERMINAL — NOT THE LIVE SYSTEM  ║"
            echo "# ║  How to reach Recovery:                                     ║"
            echo "# ║    Hold power → 'Loading startup options' → Options         ║"
            echo "# ║    → Continue → Utilities menu → Terminal                   ║"
            echo "# ╚══════════════════════════════════════════════════════════════╝"
            echo "#"
            echo "# OR just run the interactive restore script (recommended):"
            echo "#   $SCRIPT_DIR/restore.sh"
            echo "#"
            echo "# System volume:  $BASE_DEVICE"
            echo "# Preboot volume: ${PREBOOT_DEV:-(unknown — find with: diskutil list | grep Preboot)}"
            echo ""
            echo "# Step 1: Mount Preboot volume (required by bless to write boot metadata)"
            if [ -n "${PREBOOT_DEV:-}" ]; then
                echo "mount_apfs -o nobrowse $PREBOOT_DEV /System/Volumes/Preboot"
            else
                echo "# WARNING: Preboot device not detected. Find it with: diskutil list | grep Preboot"
                echo "# Then run: mount_apfs -o nobrowse /dev/diskXsY /System/Volumes/Preboot"
            fi
            echo ""
            echo "# Step 2: Mount System volume"
            echo "mount_apfs -o nobrowse $BASE_DEVICE /System/Volumes/Update/mnt1"
            echo ""
            if [ -n "$RESTORE_SNAP_UUID" ]; then
                echo "# Step 3a — PREFERRED: restore to pre-debloat state"
                echo "bless --mount /System/Volumes/Update/mnt1 --setBoot --snapshot $RESTORE_SNAP_UUID"
                echo "# UUID: $RESTORE_SNAP_UUID  Name: ${RESTORE_SNAP_NAME:-existing}"
            fi
            if [ -n "${OS_UPDATE_UUID:-}" ]; then
                echo ""
                echo "# Step 3b — FALLBACK: stock macOS (loses all debloat work)"
                echo "bless --mount /System/Volumes/Update/mnt1 --setBoot --snapshot $OS_UPDATE_UUID"
                echo "# UUID: $OS_UPDATE_UUID"
            fi
            echo ""
            echo "reboot"
        } > "$RESTORE_CMD_FILE"
        ok "RESTORE-CMD.txt written: $RESTORE_CMD_FILE"

        # Print restore command prominently in the log
        echo ""
        echo "  ╔═══════════════════════════════════════════════════════════╗"
        echo "  ║  RESTORE COMMAND — save this before rebooting            ║"
        echo "  ╠═══════════════════════════════════════════════════════════╣"
        echo "  ║  From Recovery Terminal:                                 ║"
        printf "  ║    mount_apfs -o nobrowse %-34s║\n" "${PREBOOT_DEV:-/dev/diskXsY(Preboot)} /System/Volumes/Preboot"
        printf "  ║    mount_apfs -o nobrowse %-34s║\n" "$BASE_DEVICE /System/Volumes/Update/mnt1"
        if [ -n "$RESTORE_SNAP_UUID" ]; then
        echo "  ╠═══════════════════════════════════════════════════════════╣"
        echo "  ║  PREFERRED (pre-debloat state):                          ║"
        printf "  ║    bless --mount mnt1 --setBoot --snapshot %-17s║\n" "$RESTORE_SNAP_UUID"
        fi
        if [ -n "${OS_UPDATE_UUID:-}" ]; then
        echo "  ║  FALLBACK (stock macOS, loses debloat work):             ║"
        printf "  ║    bless --mount mnt1 --setBoot --snapshot %-17s║\n" "$OS_UPDATE_UUID"
        fi
        echo "  ╠═══════════════════════════════════════════════════════════╣"
        printf "  ║  Full script: %-46s║\n" "$(basename "$(dirname "$RESTORE_CMD_FILE")")/restore.sh"
        printf "  ║  Full file:   %-46s║\n" "$(basename "$RESTORE_CMD_FILE")"
        echo "  ╚═══════════════════════════════════════════════════════════╝"
        echo ""
        log "RESTORE_SNAP_UUID=${RESTORE_SNAP_UUID:-(none)}"
        log "OS_UPDATE_UUID=${OS_UPDATE_UUID:-(not found)}"

        # HARD STOP if no restore snapshot AND --force-no-snapshot not set
        if [ -z "$RESTORE_SNAP_UUID" ] && [ "$FORCE_NO_SNAPSHOT" = false ]; then
            err "══════════════════════════════════════════════════════"
            err "  SAFETY STOP: Restore snapshot creation failed."
            err "  Will not proceed without a recovery path."
            err ""
            if [ -n "${OS_UPDATE_UUID:-}" ]; then
            err "  os.update fallback: $OS_UPDATE_UUID"
            err "  (boots stock macOS — loses all previous debloat work)"
            fi
            err ""
            err "  To override (accept risk):"
            err "    sudo ./debloat.sh --force-no-snapshot [options]"
            err ""
            err "  To free space: diskutil apfs deleteSnapshot $BASE_DEVICE -uuid <uuid>"
            err "══════════════════════════════════════════════════════"
            exit 1
        fi
        [ -z "$RESTORE_SNAP_UUID" ] && \
            warn "--force-no-snapshot: proceeding without restore snapshot (risk acknowledged)"

        # Print the restore command NOW so it appears early in the log
        if [ -n "$RESTORE_SNAP_UUID" ]; then
            echo ""
            echo "  ┌─────────────────────────────────────────────────────────────────┐"
            echo "  │  RESTORE COMMAND — run this from Recovery if boot fails:        │"
            echo "  │                                                                 │"
            printf "  │  %-67s│\n" "# 1. Mount Preboot (required by bless):"
            printf "  │  %-67s│\n" "mount_apfs -o nobrowse ${PREBOOT_DEV:-/dev/diskXsY} /System/Volumes/Preboot"
            printf "  │  %-67s│\n" "# 2. Mount System volume:"
            printf "  │  %-67s│\n" "mount_apfs -o nobrowse $BASE_DEVICE /System/Volumes/Update/mnt1"
            printf "  │  %-67s│\n" "# 3. Set boot snapshot:"
            printf "  │  %-67s│\n" "bless --mount /System/Volumes/Update/mnt1 \\"
            printf "  │        %-61s│\n" "--setBoot --snapshot $RESTORE_SNAP_UUID"
            printf "  │  %-67s│\n" "reboot"
            echo "  │                                                                 │"
            printf "  │  Or just run: %-53s│\n" "./restore.sh  (interactive, from this drive)"
            echo "  └─────────────────────────────────────────────────────────────────┘"
            echo ""
            log "RESTORE_SNAPSHOT_UUID=$RESTORE_SNAP_UUID"
        fi
    fi
    echo ""
fi # end Phase A

# ---------------------------------------------------------------------------
# --verify: run audit and exit (never modifies anything)
# ---------------------------------------------------------------------------
if [ "$VERIFY_ONLY" = true ]; then
    run_verify
    exit $?
fi

# ===========================================================================
# PHASE B: SSV MOUNT WINDOW
# ===========================================================================
if [ "$AGENTS_ONLY" = false ] && [ "$USER_ONLY" = false ] && [ "$DRY_RUN" = false ]; then
    header "PHASE B: SSV MOUNT WINDOW (must complete in < 60s)"

    # ── Per-feature confirmation ──────────────────────────────────────────────
    # Each feature shown with SSV/agent counts. User confirms y/n/a/q each one.
    # Confirmed features rebuild PATHS_FILE so only confirmed paths are deleted.
    # Skip all prompts with --yes.
    CONFIRMED_FEATURES=()
    if [ "$YES_ALL" = true ]; then
        CONFIRMED_FEATURES=("${FINAL_FEATURES[@]}")
        log "Confirmation skipped (--yes): all ${#FINAL_FEATURES[@]} features confirmed"
    else
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────────────┐"
        echo "  │  CONFIRM EACH FEATURE before SSV modification                   │"
        echo "  │  [y] process  [n] skip  [a] all remaining  [q] quit             │"
        echo "  └─────────────────────────────────────────────────────────────────┘"
        _feat_all=false
        for _feat in "${FINAL_FEATURES[@]}"; do
            if [ "$_feat_all" = true ]; then
                CONFIRMED_FEATURES+=("$_feat")
                log "AUTO-CONFIRMED: $_feat"
                continue
            fi
            # Quick per-feature count via parser
            _ssv=$(py dump_ssv_paths "" "$_feat" 2>/dev/null | wc -l | tr -d ' ')
            _agents=$(py dump_agents "$_feat" 2>/dev/null | wc -l | tr -d ' ')
            _daemons=$(py dump_daemons "$_feat" 2>/dev/null | wc -l | tr -d ' ')
            echo ""
            echo "  ─────────────────────────────────────────────────────────────────"
            printf  "  Feature:  %s\n" "$_feat"
            printf  "  SSV paths: %-5s  Agents: %-5s  Daemons: %-5s\n" "$_ssv" "$_agents" "$_daemons"
            echo "  ─────────────────────────────────────────────────────────────────"
            printf "  Process? [y/n/a/q]: "
            read -r _ans < /dev/tty
            _ansl=$(echo "$_ans" | tr '[:upper:]' '[:lower:]')
            case "$_ansl" in
                y|yes)  CONFIRMED_FEATURES+=("$_feat"); log "CONFIRMED: $_feat" ;;
                n|no)   log "SKIPPED:   $_feat" ;;
                a|all)  CONFIRMED_FEATURES+=("$_feat"); _feat_all=true
                        log "CONFIRMED: $_feat (all remaining auto-confirmed)" ;;
                q|quit|exit) log "Quit — no SSV changes made."; exit 0 ;;
                *)      log "SKIPPED:   $_feat (unrecognised: $_ans)" ;;
            esac
        done
        if [ ${#CONFIRMED_FEATURES[@]} -eq 0 ]; then
            log "No features confirmed — exiting without changes."
            exit 0
        fi
        log "Confirmed ${#CONFIRMED_FEATURES[@]} / ${#FINAL_FEATURES[@]} features"
        echo ""
        # Rebuild PATHS_FILE for confirmed features only
        log "Rebuilding deletion list for confirmed features..."
        > "$PATHS_FILE"
        COUNT_EXISTS=0
        while IFS= read -r _rp; do
            [ -z "$_rp" ] && continue
            _rp="${_rp#/}"
            if [ -e "/$_rp" ]; then
                printf '%s\0' "$MOUNT_POINT/$_rp" >> "$PATHS_FILE"
                COUNT_EXISTS=$((COUNT_EXISTS + 1))
            fi
        done < <(perl "$PARSER_PY" "$MANIFEST" dump_ssv_paths "" "${CONFIRMED_FEATURES[@]}")
        log "Confirmed SSV paths to delete: $COUNT_EXISTS"
    fi
    # Replace FINAL_FEATURES with confirmed set for all remaining phases
    FINAL_FEATURES=("${CONFIRMED_FEATURES[@]}")


    # Check SIP/authenticated-root
    SIP_STATUS=$(csrutil status 2>/dev/null)
    if echo "$SIP_STATUS" | grep -q "enabled"; then
        err "SIP is enabled. Boot to Recovery and run: csrutil disable"
        exit 1
    fi
    AUTH_STATUS=$(csrutil authenticated-root status 2>/dev/null)
    if echo "$AUTH_STATUS" | grep -q "enabled"; then
        err "Authenticated root is enabled. Boot to Recovery and run: csrutil authenticated-root disable"
        exit 1
    fi

    # [B1] Mount
    log "[B1] Mounting $BASE_DEVICE at $MOUNT_POINT..."
    mkdir -p "$MOUNT_POINT" 2>/dev/null || true

    # mount_apfs fails with ENOLCK if the kernel already has the volume open.
    # diskutil mount works reliably — use it as primary, mount_apfs as fallback.
    _do_mount() {
        local dev="$1" mp="$2"
        local _out _ret
        # Try diskutil first
        _out=$(diskutil mount -mountPoint "$mp" "$dev" 2>&1)
        _ret=$?
        if [ $_ret -eq 0 ]; then
            log "  $_out"
            return 0
        fi
        warn "  diskutil mount failed: $_out — trying mount_apfs..."
        _out=$(mount_apfs -o nobrowse "$dev" "$mp" 2>&1)
        _ret=$?
        if [ $_ret -eq 0 ]; then
            return 0
        fi
        err "  mount_apfs also failed: $_out"
        return 1
    }

    EXISTING_MOUNT=$(mount | awk -v mp="$MOUNT_POINT" '$3 == mp {print $1; exit}')
    if [ -n "$EXISTING_MOUNT" ]; then
        if [ "$EXISTING_MOUNT" != "$BASE_DEVICE" ] || \
           mount | awk -v mp="$MOUNT_POINT" '$3 == mp' | grep -qE "read-only|sealed"; then
            _UMO=$(diskutil unmount "$MOUNT_POINT" 2>&1)
            if [ $? -ne 0 ]; then
                _UMO2=$(umount "$MOUNT_POINT" 2>&1) || true
                log "  Unmount (diskutil failed: $_UMO; umount: ${_UMO2:-ok})"
            else
                log "  Unmounted: $_UMO"
            fi
            sleep 1
            _do_mount "$BASE_DEVICE" "$MOUNT_POINT" || { err "Mount failed — cannot continue"; exit 1; }
        else
            log "  $BASE_DEVICE already mounted at $MOUNT_POINT"
        fi
    else
        _do_mount "$BASE_DEVICE" "$MOUNT_POINT" || { err "Mount failed — cannot continue"; exit 1; }
    fi

    # Write test
    if ! touch "$MOUNT_POINT/.write_test" 2>/dev/null; then
        err "Mount is read-only — authenticated-root may still be enabled"
        diskutil unmount "$MOUNT_POINT" 2>/dev/null || true
        exit 1
    fi
    rm -f "$MOUNT_POINT/.write_test"
    log "Mounted RW. Starting timed window..."
    MOUNT_START=$(date +%s)

    # [B2] Delete all paths — single rm -rf call via xargs
    log "[B2] Deleting $COUNT_EXISTS paths..."
    if [ -s "$PATHS_FILE" ]; then
        # Log every path before deleting so the log shows exactly what was attempted
        log "  Paths to delete:"
        while IFS= read -r -d '' p; do
            log "    DEL: ${p#$MOUNT_POINT/}"
        done < "$PATHS_FILE"

        # Run the deletion — capture stderr so errors are logged, not swallowed
        _RM_ERR_FILE="/tmp/debloat_rm_err_$$"
        xargs -0 rm -rf < "$PATHS_FILE" 2>"$_RM_ERR_FILE" || true
        if [ -s "$_RM_ERR_FILE" ]; then
            warn "[B2] rm errors (paths that could not be deleted):"
            while IFS= read -r _rmerr; do
                warn "    $_rmerr"
            done < "$_RM_ERR_FILE"
        fi
        rm -f "$_RM_ERR_FILE"
    fi
    log "Deletions done. Elapsed: $(( $(date +%s) - MOUNT_START ))s"

    # [B3] Write TCC / Section plists
    log "[B3] Writing TCC/Section plists..."
    TCC_DIR="$MOUNT_POINT/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources"
    if [ -d "$TCC_DIR" ]; then
        # Backup originals
        [ -f "$TCC_DIR/TCCServiceList.plist" ]    && cp "$TCC_DIR/TCCServiceList.plist"    /tmp/_tcclist_orig_$$.plist
        [ -f "$TCC_DIR/SectionServiceList.plist" ] && cp "$TCC_DIR/SectionServiceList.plist" /tmp/_seclist_orig_$$.plist
        cp "$TCC_PLIST_FILE" "$TCC_DIR/TCCServiceList.plist"    2>/dev/null && log "TCCServiceList written"    || warn "TCCServiceList write failed (non-fatal)"
        cp "$SEC_PLIST_FILE" "$TCC_DIR/SectionServiceList.plist" 2>/dev/null && log "SectionServiceList written" || warn "SectionServiceList write failed (non-fatal)"
    else
        warn "SecurityPrivacyExtension not found — TCC plist patch skipped"
    fi

    # [B4] Finder MenuBar.nib patch (remove iCloud Drive from Go menu)
    log "[B4] Patching Finder MenuBar.nib..."
    NIB="$MOUNT_POINT/System/Library/CoreServices/Finder.app/Contents/Resources/Base.lproj/MenuBar.nib"
    if [ -f "$NIB" ]; then
        cp "$NIB" "${NIB}.pre-patch" 2>/dev/null || true  # backup before patching
        NIB_SIZE_BEFORE=$(wc -c < "$NIB")
        NIB_SHA_BEFORE=$(shasum -a 256 "$NIB" | awk '{print $1}')
        # Check the target strings actually exist before patching
        if grep -qF "cmdGoToICloud:" "$NIB" 2>/dev/null \
            || perl -e 'local $/; open(F,"<",$ARGV[0]) or exit 1; binmode F; my $d=<F>; exit($d=~/cmdGoToICloud:/?0:1)' "$NIB" 2>/dev/null; then
            perl -i -pe 's/cmdGoToICloud:/cmdGoToICloud_/g; s/cmdGoToDataSeparatedICloud:/cmdGoToDataSeparatedICloud_/g' "$NIB" 2>/dev/null
            NIB_SIZE_AFTER=$(wc -c < "$NIB")
            NIB_SHA_AFTER=$(shasum -a 256 "$NIB" | awk '{print $1}')
            if [ "$NIB_SIZE_BEFORE" -eq "$NIB_SIZE_AFTER" ] && [ "$NIB_SHA_BEFORE" != "$NIB_SHA_AFTER" ]; then
                log "Finder MenuBar.nib patched (size preserved: $NIB_SIZE_BEFORE bytes, SHA256 changed — confirmed)"
            elif [ "$NIB_SHA_BEFORE" = "$NIB_SHA_AFTER" ]; then
                warn "Finder MenuBar.nib SHA256 unchanged — strings may not have been present in binary form"
            else
                warn "Finder MenuBar.nib size changed ($NIB_SIZE_BEFORE → $NIB_SIZE_AFTER) — patch imprecise, restoring backup"
                cp "${NIB}.pre-patch" "$NIB" 2>/dev/null || true
            fi
        else
            log "Finder MenuBar.nib: target strings not found — already patched or NIB format changed, skipping"
        fi
    else
        warn "Finder MenuBar.nib not found — skipping"
    fi

    # [B4b] storeuid Info.plist patch (remove Apple menu "App Store" item)
    log "[B4b] Patching storeuid Info.plist (removing CFBundleVisibleComponentName)..."
    STOREUID_PLIST="$MOUNT_POINT/System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Resources/storeuid.app/Contents/Info.plist"
    if [ -f "$STOREUID_PLIST" ]; then
        cp "$STOREUID_PLIST" /tmp/_storeuid_info_original.plist 2>/dev/null || true
        if /usr/libexec/PlistBuddy -c "Print :CFBundleVisibleComponentName" "$STOREUID_PLIST" &>/dev/null; then
            /usr/libexec/PlistBuddy -c "Delete :CFBundleVisibleComponentName" "$STOREUID_PLIST" \
                && log "storeuid CFBundleVisibleComponentName deleted — App Store item will not appear in Apple menu" \
                || warn "PlistBuddy delete failed on storeuid Info.plist (non-fatal)"
        else
            log "storeuid Info.plist: CFBundleVisibleComponentName already absent — skipping"
        fi
    else
        warn "storeuid Info.plist not found at expected path — skipping"
    fi

    # [B5] Bless — MUST be last operation, MUST succeed
    log "[B5] Running bless --create-snapshot --setBoot..."
    ELAPSED=$(( $(date +%s) - MOUNT_START ))
    log "Time in mount window before bless: ${ELAPSED}s"
    if [ "$ELAPSED" -gt 45 ]; then
        warn "Mount window at ${ELAPSED}s — approaching 60s kernel watchdog budget"
    fi

    BLESS_TARGET="$MOUNT_POINT/System/Library/CoreServices"
    if [ ! -d "$BLESS_TARGET" ]; then
        err "CoreServices not found — cannot bless. SSV modified but no boot snapshot created."
        err "Manual recovery:"
        err "  mount_apfs -o nobrowse ${PREBOOT_DEV:-/dev/diskXsY(Preboot)} /System/Volumes/Preboot"
        err "  mount_apfs -o nobrowse $BASE_DEVICE $MOUNT_POINT"
        err "  bless --mount $MOUNT_POINT --create-snapshot --setBoot"
        err "  reboot"
        err "  — or run restore.sh from this drive for an interactive menu —"
        exit 1
    fi

    BLESS_ERR_FILE="/tmp/debloat_bless_err_$$"
    if bless --mount "$MOUNT_POINT" --create-snapshot --setBoot 2>"$BLESS_ERR_FILE"; then
        ELAPSED=$(( $(date +%s) - MOUNT_START ))
        ok "bless SUCCESS (total mount window: ${ELAPSED}s)"
        BLESS_OK=true
        # Capture the newly-created boot snapshot UUID and record it
        BOOT_SNAP_UUID=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null \
            | awk '/^\+-- /{uuid=$NF} /com\.apple\.bless\./{last=uuid} END{print last}')
        _write_snap_meta "$BOOT_SNAP_UUID" "boot" "${CONFIRMED_FEATURES[*]:-}"
    else
        BLESS_ERR=$(cat "$BLESS_ERR_FILE" 2>/dev/null)
        err "bless FAILED: $BLESS_ERR"
        err "SSV modified but new snapshot NOT set as boot target."
        # Find the existing com.apple.os.update snapshot as recovery target
        OS_UPDATE_UUID=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null             | awk '/com\.apple\.os\.update/{found=1} found && /XID:/{print $2; exit}'             | head -1)
        err ""
        err "═══ RECOVERY OPTIONS (choose one) ════════════════════════════"
        err "  Option 1 — retry bless with Preboot mounted (most likely fix):"
        err "    mount_apfs -o nobrowse ${PREBOOT_DEV:-/dev/diskXsY(Preboot)} /System/Volumes/Preboot"
        err "    mount_apfs -o nobrowse $BASE_DEVICE $MOUNT_POINT"
        err "    bless --mount $MOUNT_POINT --create-snapshot --setBoot"
        err "    reboot"
        err "  — or run restore.sh from this drive for an interactive menu —"
        if [ -n "$OS_UPDATE_UUID" ]; then
        err "  Option 2 — boot original snapshot (reverts all SSV changes):"
        err "    mount_apfs -o nobrowse ${PREBOOT_DEV:-/dev/diskXsY(Preboot)} /System/Volumes/Preboot"
        err "    mount_apfs -o nobrowse $BASE_DEVICE $MOUNT_POINT"
        err "    bless --mount $MOUNT_POINT --setBoot --snapshot $OS_UPDATE_UUID"
        err "    reboot"
        fi
        err "  Option 3 — Recovery OS reinstall (preserves user data):"
        err "    Hold power → Options → Reinstall macOS"
        err "═══════════════════════════════════════════════════════════════"
        BLESS_OK=false
    fi
    rm -f "$BLESS_ERR_FILE"

    # Cleanup temp files
    rm -f "$PATHS_FILE" "$TCC_PLIST_FILE" "$SEC_PLIST_FILE"

fi # end Phase B

# ===========================================================================
# PHASE C: POST-MOUNT VERIFICATION & SNAPSHOT CLEANUP
# ===========================================================================
if [ "$AGENTS_ONLY" = false ] && [ "$USER_ONLY" = false ] && [ "$DRY_RUN" = false ]; then
    header "PHASE C: POST-MOUNT VERIFICATION"

    # [C1] Verify new boot snapshot
    log "[C1] Verifying new boot snapshot..."
    NEW_BOOT=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null | grep "Will root to" | head -1)
    if [ -n "$NEW_BOOT" ]; then
        ok "Boot snapshot: $NEW_BOOT"
    else
        warn "No snapshot marked 'Will root to'. Check: diskutil apfs listSnapshots $SNAP_DEV"
    fi

    # [C2] Snapshot cleanup — delete stale bless snapshots, preserve restore snapshot
    # Rules:
    #   KEEP: com.apple.bless.* that is "Will root to" (active boot target)
    #   KEEP: com.apple.debloat.restore.* (rolling restore — never delete)
    #   KEEP: com.apple.os.update.* (Apple original sealed SSV)
    #   DELETE: any other com.apple.bless.* (stale from previous runs)
    log "[C2] Cleaning up stale bless snapshots (preserving restore + boot)..."
    ACTIVE_BLESS_UUID=$(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null         | awk '/^\+-- /{uuid=$NF} /Will root to/{print uuid; exit}')
    log "Active boot snapshot UUID: ${ACTIVE_BLESS_UUID:-(not found)}"
    log "Restore snapshot UUID:     ${RESTORE_SNAP_UUID:-(none created this run)}"

    STALE_DELETED=0
    while IFS= read -r snap_uuid; do
        [ -z "$snap_uuid" ] && continue
        # Never delete the active boot target
        [ "$snap_uuid" = "$ACTIVE_BLESS_UUID" ] && continue
        # Never delete our restore snapshot
        [ "$snap_uuid" = "${RESTORE_SNAP_UUID:-}" ] && continue
        if diskutil apfs deleteSnapshot "$BASE_DEVICE" -uuid "$snap_uuid" >/dev/null 2>&1; then
            ok "Deleted stale bless snapshot: $snap_uuid"
            STALE_DELETED=$((STALE_DELETED + 1))
        else
            warn "Could not delete snapshot: $snap_uuid (may already be gone)"
        fi
    done < <(diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null         | awk '/^\+-- /{uuid=$NF} /com\.apple\.bless\./{print uuid}')
    log "Stale bless snapshots deleted: $STALE_DELETED"

    log ""
    log "Current snapshots after cleanup:"
    diskutil apfs listSnapshots "$SNAP_DEV" 2>/dev/null         | grep -E "com\.apple\.(bless|debloat|os\.update)\.|Will root to"         || log "(no relevant snapshots found)"

    # Re-print the restore command here so it appears post-bless in the log too
    if [ -n "${RESTORE_SNAP_UUID:-}" ]; then
        echo ""
        log "══════════════════════════════════════════════════════════════"
        log "RESTORE SNAPSHOT: $RESTORE_SNAP_UUID"
        log "RESTORE COMMAND (from Recovery Terminal if boot fails):"
        log "  # 1. Mount Preboot (required by bless):"
        log "  mount_apfs -o nobrowse ${PREBOOT_DEV:-/dev/diskXsY(Preboot)} /System/Volumes/Preboot"
        log "  # 2. Mount System volume:"
        log "  mount_apfs -o nobrowse $BASE_DEVICE /System/Volumes/Update/mnt1"
        log "  # 3. Set boot snapshot:"
        log "  bless --mount /System/Volumes/Update/mnt1 --setBoot --snapshot $RESTORE_SNAP_UUID"
        log "  reboot"
        log "  — or run restore.sh from this drive for an interactive menu —"
        log "══════════════════════════════════════════════════════════════"
        echo ""
    fi

    # [C3] Monitor logs for 10s — timeout ensures log stream is killed when head exits
    log "[C3] Monitoring system logs for 10s..."
    timeout 12 log stream --predicate 'eventMessage contains "error"' 2>/dev/null \
        | grep -v "^Filtering" | head -20 || true

fi # end Phase C

# ===========================================================================
# PHASE D: DISABLE LAUNCH AGENTS & DAEMONS (live system, no reboot needed)
# ===========================================================================
if [ "$SSV_ONLY" = false ] && [ "$USER_ONLY" = false ]; then
    header "PHASE D: DISABLE LAUNCH AGENTS & DAEMONS"

    # Resolve real user UID (works under sudo)
    UID_CURRENT="${SUDO_UID:-$(id -u)}"
    log "Targeting gui/$UID_CURRENT domain"

    AGENT_DISABLED=0
    AGENT_ALREADY=0
    DAEMON_DISABLED=0
    DAEMON_ALREADY=0

    # Cache disabled lists once, refresh after each feature batch
    _AGENT_CACHE=""
    _DAEMON_CACHE=""
    refresh_agent_cache()  { _AGENT_CACHE=$(launchctl  print-disabled "gui/$UID_CURRENT" 2>/dev/null); }
    refresh_daemon_cache() { _DAEMON_CACHE=$(launchctl print-disabled "system"            2>/dev/null); }
    refresh_agent_cache
    refresh_daemon_cache

    # Pre-flight: ensure critical agents are ENABLED before we touch anything
    log "[D0] Re-enabling protected agents (idempotent guard)..."
    for must_keep in \
        "gui/$UID_CURRENT/com.apple.xtyped" \
        "gui/$UID_CURRENT/com.apple.mediaremoteagent" \
        "gui/$UID_CURRENT/com.apple.rcd" \
        "gui/$UID_CURRENT/com.apple.BTServer.cloudpairing" \
        "gui/$UID_CURRENT/com.apple.bluetoothaudiod" \
        "gui/$UID_CURRENT/com.apple.cloudpaird" \
        "system/com.apple.AirPlayXPCHelper" \
        "system/com.apple.audioanalyticsd" \
        "system/com.apple.audio.isolated.historicalaudiod" \
        "system/com.apple.audio.coreaudiod" \
        "system/com.apple.audiomxd" \
        "system/com.apple.PerfPowerServicesExtended" \
        "system/com.apple.PerfPowerServices" \
    ; do
        launchctl enable "$must_keep" 2>/dev/null || true
    done
    log "Protected agents confirmed enabled."

    disable_agent() {
        # Accepts full label (com.apple.foo) — dump_agents already resolves prefix
        local label="$1"
        if [ "$DRY_RUN" = true ]; then
            echo "    DISABLE AGENT: $label"; return
        fi
        if echo "$_AGENT_CACHE" | grep -qF "\"$label\" => disabled"; then
            AGENT_ALREADY=$((AGENT_ALREADY + 1)); return
        fi
        local _lc_err
        _lc_err=$(launchctl disable "gui/$UID_CURRENT/$label" 2>&1)
        if [ $? -ne 0 ] && [ -n "$_lc_err" ]; then
            warn "  launchctl disable agent $label: $_lc_err"
        fi
        AGENT_DISABLED=$((AGENT_DISABLED + 1))
    }

    disable_daemon() {
        local label="$1"
        if [ "$DRY_RUN" = true ]; then
            echo "    DISABLE DAEMON: $label"; return
        fi
        if echo "$_DAEMON_CACHE" | grep -qF "\"$label\" => disabled"; then
            DAEMON_ALREADY=$((DAEMON_ALREADY + 1)); return
        fi
        local _lc_err
        _lc_err=$(launchctl disable "system/$label" 2>&1)
        if [ $? -ne 0 ] && [ -n "$_lc_err" ]; then
            warn "  launchctl disable daemon $label: $_lc_err"
        fi
        sleep 0.05
        DAEMON_DISABLED=$((DAEMON_DISABLED + 1))
    }

    # Single-call: get all agents and daemons across all features
    log "[D] Disabling agents..."
    while IFS= read -r agent; do
        [ -n "$agent" ] && disable_agent "$agent"
    done < <(perl "$PARSER_PY" "$MANIFEST" dump_agents "${FINAL_FEATURES[@]}")
    refresh_agent_cache

    log "[D] Disabling daemons..."
    while IFS= read -r daemon; do
        [ -n "$daemon" ] && disable_daemon "$daemon"
    done < <(perl "$PARSER_PY" "$MANIFEST" dump_daemons "${FINAL_FEATURES[@]}")
    refresh_daemon_cache

     # Bootout pass — manifest-driven, no hardcoded list
     if [ "$DRY_RUN" = false ]; then
         _BL=$(perl "$PARSER_PY" "$MANIFEST" dump_daemons "${FINAL_FEATURES[@]}" 2>/dev/null)
         if [ -n "$_BL" ]; then
             log "[D] Booting out running daemons for confirmed features..."
             while IFS= read -r _bd; do
                 [ -z "$_bd" ] && continue
                 _bo_err=$(launchctl bootout "system/$_bd" 2>&1)
                 if [ $? -eq 0 ]; then
                     log "  Booted out: $_bd"
                 else
                     # Exit 36 = "No such process" — not running, not an error
                     if echo "$_bo_err" | grep -qE "No such process|36"; then
                         log "  Not running: $_bd"
                     else
                         warn "  bootout $_bd: $_bo_err"
                     fi
                 fi
             done <<< "$_BL"
         fi
     fi

     # Bootout pass — agents (terminates running instances immediately after disable)
     if [ "$DRY_RUN" = false ]; then
         _AL=$(perl "$PARSER_PY" "$MANIFEST" dump_agents "${FINAL_FEATURES[@]}" 2>/dev/null)
         if [ -n "$_AL" ]; then
             log "[D] Booting out running agents for confirmed features..."
             while IFS= read -r _ba; do
                 [ -z "$_ba" ] && continue
                 _bo_err=$(launchctl bootout "gui/$UID_CURRENT/$_ba" 2>&1)
                 if [ $? -eq 0 ]; then
                     log "  Booted out: $_ba"
                 else
                     # Exit 36 = "No such process" — not running, not an error
                     if echo "$_bo_err" | grep -qE "No such process|36"; then
                         log "  Not running: $_ba"
                     else
                         warn "  bootout $_ba: $_bo_err"
                     fi
                 fi
             done <<< "$_AL"
         fi
     fi

     log ""
    log "Agents disabled this run:  $AGENT_DISABLED"
    log "Agents already disabled:   $AGENT_ALREADY"
    log "Daemons disabled this run: $DAEMON_DISABLED"
    log "Daemons already disabled:  $DAEMON_ALREADY"

fi # end Phase D

# ===========================================================================
# PHASE E: PLUGINKIT SUPPRESS
# ===========================================================================
if [ "$SSV_ONLY" = false ] && [ "$USER_ONLY" = false ]; then
    header "PHASE E: PLUGINKIT SUPPRESS"

    PK_COUNT=0
    PK_FAIL=0
    while IFS= read -r bundle_id; do
        [ -z "$bundle_id" ] && continue
        if [ "$DRY_RUN" = true ]; then
            echo "    PLUGINKIT IGNORE: $bundle_id"
        else
            _pk_err=$(pluginkit -e ignore -i "$bundle_id" 2>&1)
            if [ $? -eq 0 ]; then
                PK_COUNT=$((PK_COUNT + 1))
            else
                warn "  pluginkit ignore $bundle_id: $_pk_err"
                PK_FAIL=$((PK_FAIL + 1))
            fi
        fi
    done < <(perl "$PARSER_PY" "$MANIFEST" dump_pluginkit "${FINAL_FEATURES[@]}")
    log "PluginKit extensions suppressed: $PK_COUNT  failed: $PK_FAIL"

fi # end Phase E

# ===========================================================================
# PHASE F: USER DATA CLEANUP
# Containers, Group Containers, Preferences, Caches
# IMPORTANT: NEVER blanket-delete — only entries for removed/disabled apps.
# ===========================================================================
if [ "$SSV_ONLY" = false ] && [ "$AGENTS_ONLY" = false ]; then
    header "PHASE F: USER DATA CLEANUP"

    # Resolve real user home dir
    if [ -n "${SUDO_USER:-}" ]; then
        USER_HOME=$(dscl . -read /Users/"$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        [ -z "$USER_HOME" ] && USER_HOME=$(eval echo "~$SUDO_USER")
    else
        USER_HOME="$HOME"
    fi
    log "User home: $USER_HOME"

    F_DELETED=0
    F_MISSING=0

    safe_rm() {
        local path="$1"
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [ "$DRY_RUN" = true ]; then
                echo "    [DRY]  rm -rf  $path"
                F_DELETED=$((F_DELETED + 1))
            else
                local _rm_err
                _rm_err=$(rm -rf "$path" 2>&1)
                # rm -rf rarely exits nonzero — verify deletion by checking existence
                if [ ! -e "$path" ] && [ ! -L "$path" ]; then
                    F_DELETED=$((F_DELETED + 1))
                else
                    warn "Failed to remove (still exists): $path${_rm_err:+ — $_rm_err}"
                fi
            fi
        else
            F_MISSING=$((F_MISSING + 1))
        fi
    }

    # Single call: dump all user data paths tagged by type
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        _tag="${line%%	*}"
        _upath="${line#*	}"
        case "$_tag" in
            pref)
                safe_rm "$_upath"
                safe_rm "$_upath.lockfile"
                ;;
            *)
                safe_rm "$_upath"
                ;;
        esac
    done < <(perl "$PARSER_PY" "$MANIFEST" dump_user_data "$USER_HOME" "${FINAL_FEATURES[@]}")

    # Rebuild LaunchServices database
    if [ "$DRY_RUN" = false ]; then
        log "[F] Rebuilding LaunchServices database..."
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -kill -seed -r -f 2>/dev/null && ok "LaunchServices DB rebuilt" || warn "lsregister failed (non-fatal)"
    fi

    log "User items deleted: $F_DELETED"
    log "User items not found (skipped): $F_MISSING"

fi # end Phase F

# ===========================================================================
# PHASE G: POST-DEBLOAT CLEANUP
# Invokes cleanup.sh with the same feature set to purge group containers,
# stale CoreSpotlight receiver registrations, Spotlight EnabledPreferenceRules,
# LaunchServices DB, icon services cache, and trigger Spotlight reindex.
# Skipped on --dry-run, --ssv-only, and --agents-only runs.
# ===========================================================================
if [ -x "$SCRIPT_DIR/cleanup.sh" ] \
   && [ "$DRY_RUN" = false ] \
   && [ "$SSV_ONLY" = false ] \
   && [ "$AGENTS_ONLY" = false ] \
   && [ -n "$FEATURE_FILTER" ]; then
    header "PHASE G: POST-DEBLOAT CLEANUP"
    log "Invoking cleanup.sh --features $FEATURE_FILTER ..."
    bash "$SCRIPT_DIR/cleanup.sh" --features "$FEATURE_FILTER" --yes 2>&1 | tee -a "$LOG" \
        || warn "cleanup.sh reported errors (non-fatal — see above)"
fi # end Phase G
# ===========================================================================
header "SUMMARY"
log "Features processed: ${#FINAL_FEATURES[@]}"
log "Log file: $LOG"
echo ""

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN complete — no changes made."
else
    if [ "${BLESS_OK:-}" = true ]; then
        echo ""
        echo "  ╔══════════════════════════════════════════════════════════════╗"
        echo "  ║  STATUS: SUCCESS                                             ║"
        echo "  ║  New boot snapshot created and set as active.               ║"
        echo "  ║                                                              ║"
        echo "  ║  REBOOT NOW for all SSV changes to take effect.             ║"
        echo "  ║                                                              ║"
        echo "  ║  IMPORTANT:                                                  ║"
        echo "  ║  - macOS software updates will NO LONGER WORK               ║"
        echo "  ╚══════════════════════════════════════════════════════════════╝"
        echo ""
        if [ -n "${RESTORE_SNAP_UUID:-}" ]; then
            echo "  ┌─────────────────────────────────────────────────────────────────┐"
            echo "  │  RESTORE COMMAND — if system fails to boot after reboot:        │"
            echo "  │  1. Hold power button → Options → Recovery → Terminal           │"
            echo "  │  2. Run:                                                        │"
            printf "  │     %-63s│\n" "mount_apfs -o nobrowse ${PREBOOT_DEV:-/dev/diskXsY} /System/Volumes/Preboot"
            printf "  │     %-63s│\n" "mount_apfs -o nobrowse $BASE_DEVICE /System/Volumes/Update/mnt1"
            printf "  │     %-63s│\n" "bless --mount /System/Volumes/Update/mnt1 --setBoot \\"
            printf "  │           %-57s│\n" "--snapshot $RESTORE_SNAP_UUID"
            echo "  │     reboot                                                      │"
            echo "  │                                                                 │"
            printf "  │  Or run: %-59s│\n" "./restore.sh  (interactive, from your external drive)"
            printf "  │  Restore UUID: %-53s│\n" "$RESTORE_SNAP_UUID"
            echo "  └─────────────────────────────────────────────────────────────────┘"
            echo ""
        fi
    elif [ "${SSV_ONLY:-}" = false ] && [ "${AGENTS_ONLY:-}" = true ]; then
        echo ""
        log "Agents/daemons disabled. Reboot to fully take effect."
    else
        echo ""
        log "Partial run complete."
        [ "${BLESS_OK:-}" = false ] && err "bless FAILED — run bless manually before rebooting."
    fi
fi

exit 0