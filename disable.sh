#!/bin/bash
# ==============================================================================
# DISABLE — macOS 26 / Apple Silicon development machine
# Disables all non-essential Apple services on a pure development machine:
# telemetry, analytics, iCloud, Siri, Mail, media, gaming, AI/ML stacks,
# App Store engagement daemons, and anything with no development utility.
#
# Every item has two branches:
#   d  → disable  (apply the disabled state)
#   r  → restore  (revert to macOS default)
# This guarantees you can always undo any change cleanly.
#
# USAGE:
#   sudo ./disable.sh [OPTIONS]
#
# OPTIONS:
#   --dry-run          Show what would change; make no changes
#   --yes              Skip all confirmation prompts; disable everything
#   --list             List all items and descriptions, then exit
#   --group  g1,g2     Process only these groups (comma-separated)
#   --skip   g1,k1     Skip these groups or individual keys
#   --item   k1,k2     Process only these individual keys
#   --restore          Apply the RESTORE branch for all matched items
#                      (re-enables everything back to macOS defaults)
#
# CONFIRMATION (default — interactive without --yes or --dry-run):
#   Each item shows its current state, macOS default, and disabled value.
#   Prompt: [d] disable  [r] restore  [n] skip  [a] disable all  [q] quit
#
# EXAMPLES:
#   sudo ./disable.sh --dry-run                        # preview all
#   sudo ./disable.sh --yes                            # disable everything
#   sudo ./disable.sh --yes --restore                  # restore everything
#   sudo ./disable.sh --group telemetry,siri           # two groups
#   sudo ./disable.sh --item promotedcontentd          # single item
#   sudo ./disable.sh --skip icloud --yes              # all except icloud
#   ./disable.sh --list                                # show all keys+methods
#
# GROUPS:
#   telemetry    Apple analytics, diagnostics, usage reporting, and crash data
#   siri         Siri daemon stack, suggestions, NLP, speech recognition
#   icloud       iCloud sync, Photos, Drive, Keychain, relay services
#   media        iTunes Cloud, AirPlay, AirDrop, Handoff, Continuity Camera
#   apple_intel  Apple Intelligence / generative AI / Private Cloud Compute
#   appstore     App Store ads, engagement tracking, A/B trials, commerce
#   mail         Mail, Calendar, Contacts, Reminders background daemons
#   social       Maps sync, News, Stocks, Weather, Find My, HomeKit
#   gaming       Game Center, Game Mode, game controller daemons
#   mdm          Remote Management, Managed Settings subscriber stack
#   updates      Software Update auto-check and background download daemons
#
# METHODS (shown in --list output):
#   launchctl    launchctl bootout / bootstrap (user or system domain)
#   defaults     defaults write to a preference domain
#   systemsetup  systemsetup command-line tool
#   hosts        /etc/hosts null-route entry
#   plist        Direct plist write via PlistBuddy or defaults on system path
#
# PATTERN IMPROVEMENTS over optimize.sh:
#   1. Single _disable_item helper replaces the two-helper confirm/dry split.
#   2. Every apply function takes a single $ACTION variable (disable|restore)
#      instead of encoding both branches via numeric return codes — clearer.
#   3. DISABLE_LIST registry adds a 4th METHOD column shown in --list.
#   4. _lctl helper encapsulates the launchctl disable+stop / enable+start
#      pattern with graceful fallback for already-unloaded services.
#   5. --restore flag flips all actions to the restore branch globally,
#      eliminating a separate restore script.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$SCRIPT_DIR/disable-$(date +%Y%m%d-%H%M%S).log"

DRY_RUN=false
YES_ALL=false
LIST_ONLY=false
RESTORE_MODE=false
GROUP_FILTER=""
ITEM_FILTER=""
SKIP_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true ;;
        --yes)      YES_ALL=true ;;
        --list)     LIST_ONLY=true ;;
        --restore)  RESTORE_MODE=true ;;
        --group)    GROUP_FILTER="$2"; shift ;;
        --item)     ITEM_FILTER="$2"; shift ;;
        --skip)     SKIP_FILTER="$2"; shift ;;
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
ok()     { echo "  [$(ts)] OK   $*"; }
warn()   { echo "  [$(ts)] WARN $*"; }
err()    { echo "  [$(ts)] ERR  $*"; }
header() { echo ""; echo "======================================================================"; echo "  $*"; echo "======================================================================"; }
sep()    { echo "  ──────────────────────────────────────────────────────────────────"; }

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ] && [ "$LIST_ONLY" = false ]; then
    err "Must be run as root: sudo ./disable.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Real user detection (sudo-safe defaults writes)
# ---------------------------------------------------------------------------
REAL_USER="${SUDO_USER:-}"
[ -z "$REAL_USER" ] && REAL_USER=$(stat -f "%Su" /dev/console 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER=$(logname 2>/dev/null || true)
{ [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; } && REAL_USER="$USER"
REAL_HOME=$(eval echo "~$REAL_USER")
REAL_UID=$(id -u "$REAL_USER" 2>/dev/null || echo "$(id -u)")

dfw() { sudo -u "$REAL_USER" defaults "$@"; }

# ---------------------------------------------------------------------------
# DISABLE REGISTRY
# Format: "KEY|GROUP|METHOD|DESCRIPTION"
# METHOD: launchctl | defaults | systemsetup | hosts | plist
# ---------------------------------------------------------------------------
DISABLE_LIST=(
    # ── telemetry ────────────────────────────────────────────────────────────
    "analyticsagent|telemetry|launchctl|analyticsagent — CoreAnalytics user agent that batches and uploads device usage data to Apple. Disable: launchctl bootout. Restore: launchctl bootstrap. Impact: Apple receives no usage telemetry from this machine."
    "analyticsd|telemetry|launchctl|analyticsd — System-level analytics daemon that collects hardware and software diagnostics for Apple. Disable: launchctl bootout system domain. Restore: bootstrap. Impact: Eliminates the primary telemetry collection pipeline."
    "biomed|telemetry|launchctl|biomed — Biome data collector; captures a continuous stream of on-device behavioural signals (app usage patterns, tap events, scroll velocity) used for Siri personalisation and telemetry. Disable: launchctl bootout. Restore: bootstrap. Impact: No behavioural fingerprint data collected."
    "biomesyncd|telemetry|launchctl|biomesyncd — Syncs Biome data to iCloud so it is shared across Apple devices. Disable: launchctl bootout. Restore: bootstrap. Impact: Stops cross-device behavioural data sync."
    "BiomeAgent|telemetry|launchctl|BiomeAgent — User-domain agent that feeds events into the Biome pipeline. Works alongside biomed. Disable: launchctl bootout gui domain. Restore: bootstrap. Impact: Cuts the user-space half of the Biome ingestion pipeline."
    "UsageTrackingAgent|telemetry|launchctl|UsageTrackingAgent — Tracks which apps are open and for how long; data goes to Screen Time and Apple analytics servers. Disable: launchctl bootout. Restore: bootstrap. Impact: No per-app usage timestamps recorded or reported."
    "inputanalyticsd|telemetry|launchctl|inputanalyticsd — Records keyboard, mouse, and trackpad event statistics for Apple input analytics. Disable: launchctl bootout. Restore: bootstrap. Impact: Keystroke and gesture patterns not collected."
    "wifianalyticsd|telemetry|launchctl|wifianalyticsd — Collects WiFi signal strength, roaming events, and connection quality metrics for Apple. Disable: launchctl bootout. Restore: bootstrap. Impact: Network performance telemetry stopped."
    "audioanalyticsd|telemetry|launchctl|audioanalyticsd — Records audio device usage events (plug/unplug, sample rates, codec selection) for Apple analytics. Disable: launchctl bootout. Restore: bootstrap. Impact: Audio device telemetry stopped."
    "historicalaudiod|telemetry|launchctl|historicalaudiod — Maintains a rolling history of audio output levels; feeds into hearing health features and Apple analytics. Disable: launchctl bootout. Restore: bootstrap. Impact: Audio level history not retained or reported."
    "diagnosticsagent|telemetry|launchctl|diagnostics_agent — User-domain agent that gathers crash logs and diagnostic reports and queues them for submission to Apple. Disable: launchctl bootout. Restore: bootstrap. Impact: Crash and diagnostic data no longer submitted automatically."
    "diagnosticextensionsd|telemetry|launchctl|diagnosticextensionsd — Manages third-party diagnostic extensions; also used by Apple for extended diagnostic data collection. Disable: launchctl bootout. Restore: bootstrap. Impact: Extended diagnostics pipeline disabled."
    "ReportCrash|telemetry|launchctl|ReportCrash — Watches for application crashes and writes crash reports; also submits them to Apple if analytics consent is given. Disable: launchctl bootout. Restore: bootstrap. Impact: Crash reports still written to ~/Library/Logs/DiagnosticReports but not auto-submitted."
    "osanalyticshelper|telemetry|launchctl|osanalyticshelper — Helper that assists the OS analytics pipeline with privileged data collection tasks. Disable: launchctl bootout. Restore: bootstrap. Impact: Privileged analytics collection helper removed from the chain."
    "ecosystemanalyticsd|telemetry|launchctl|ecosystemanalyticsd — Collects ecosystem-level telemetry (cross-device usage patterns, ecosystem health signals) for Apple. New in macOS 26. Disable: launchctl bootout system. Restore: bootstrap. Impact: Ecosystem telemetry not collected."
    "geoanalyticsd|telemetry|launchctl|geoanalyticsd — Collects geo/location analytics data (frequency of location queries, map interaction patterns) for Apple. Disable: launchctl bootout. Restore: bootstrap. Impact: Geo analytics not collected."
    "tailspind|telemetry|launchctl|tailspind — Tailspin daemon; records a continuous circular buffer of CPU, disk, and memory events used for performance telemetry and crash triage. High background I/O on a dev machine. Disable: launchctl bootout. Restore: bootstrap. Impact: Performance event buffer not maintained; reduces background disk writes."
    "rtcreportingd|telemetry|launchctl|rtcreportingd — Real-time communications reporting daemon; submits FaceTime and CallKit call-quality metrics to Apple. Disable: launchctl bootout. Restore: bootstrap. Impact: Call quality metrics not reported (no FaceTime on this machine anyway)."
    "PerfPowerTelemetry|telemetry|launchctl|PerfPowerTelemetryClientRegistrationService — Registers apps with Apple's power and performance telemetry framework so their CPU/GPU/power data is included in aggregate reports. Disable: launchctl bootout. Restore: bootstrap. Impact: This machine's power consumption data excluded from Apple telemetry."
    "CloudTelemetryService|telemetry|launchctl|CloudTelemetryService — Uploads telemetry events to Apple's cloud telemetry pipeline. 4 instances observed running simultaneously. Disable: db write + bootout. Restore: db remove. Impact: Cloud telemetry submissions stopped entirely."
    "spotlightknowledged_importer|telemetry|launchctl|spotlightknowledged.importer — Imports knowledge data into Spotlight's knowledge graph for Siri Suggestions and contextual search. Runs after Spotlight indexing bursts. Disable: db write + bootout. Restore: db remove. Impact: Knowledge graph not updated; Spotlight suggestions less personalised."
    "spotlightknowledged_updater|telemetry|launchctl|spotlightknowledged.updater — Periodically updates the Spotlight knowledge graph with fresh signals from app usage and file access patterns. Disable: db write + bootout. Restore: db remove. Impact: Knowledge graph updates stop."
    "knowledge_agent|telemetry|launchctl|knowledge-agent — Manages the on-device knowledge store used by Siri Suggestions, Spotlight contextual results, and proactive intelligence features. Disable: db write + bootout. Restore: db remove. Impact: Knowledge store not updated; proactive suggestions not personalised."
    "knowledgeconstructiond|telemetry|launchctl|knowledgeconstructiond — Constructs structured knowledge from unstructured signals (emails, messages, calendar events) to build the Siri/Spotlight knowledge graph. New in macOS 26. Disable: db write + bootout. Restore: db remove. Impact: Knowledge construction pipeline stops."
    "analyticsagent_defaults|telemetry|defaults|AutomaticCheckEnabled=false in com.apple.SubmitDiagInfo — Preference that gates whether the diagnostics submission UI offers to send data to Apple. Disable: defaults write false. Restore: defaults write true. Impact: Diagnostic submission prompt suppressed at the preference layer in addition to the daemon-level disable."
    "diag_autosend|telemetry|defaults|AutoSubmit=false in com.apple.SubmitDiagInfo — Controls whether crash/diagnostic reports are automatically submitted to Apple without user confirmation. Disable: defaults write false. Restore: defaults delete (macOS default is unset = no auto-submit). Impact: Ensures no crash data is silently uploaded even if the daemon restarts."
    # ── siri ─────────────────────────────────────────────────────────────────
    "assistantd|siri|launchctl|assistantd — Core Siri daemon; handles voice recognition dispatch, natural language query routing, and Siri server communication. Disable: launchctl bootout. Restore: bootstrap. Impact: Siri entirely non-functional; no voice queries processed."
    "siriknowledged|siri|launchctl|siriknowledged — Maintains the on-device Siri knowledge graph: app usage, contacts relevance, location frequency, and learned shortcuts. Disable: launchctl bootout. Restore: bootstrap. Impact: Siri personalisation data not built or updated."
    "siriinferenced|siri|launchctl|siriinferenced — Runs on-device ML inference for Siri Suggestions (proactive app launches, next-action predictions). Consumes CPU periodically in the background. Disable: launchctl bootout. Restore: bootstrap. Impact: No proactive app or action suggestions generated."
    "sirittsd|siri|launchctl|sirittsd — Siri Text-to-Speech daemon; synthesises Siri's voice responses. Disable: launchctl bootout. Restore: bootstrap. Impact: Siri voice output non-functional (irrelevant without assistantd)."
    "SiriAnalytics|siri|launchctl|siri.context.service — Siri context service; provides real-time contextual signals (foreground app, selected text, clipboard) to Siri for context-aware responses. Disable: launchctl bootout. Restore: bootstrap. Impact: Siri loses foreground app context awareness."
    "assistant_cdmd|siri|launchctl|assistant_cdmd — Continuous Dialogue Manager; maintains conversational context across multi-turn Siri interactions. Disable: launchctl bootout. Restore: bootstrap. Impact: Multi-turn Siri conversations not tracked."
    "naturallanguaged|siri|launchctl|naturallanguaged — On-device Natural Language Processing daemon used by Siri Suggestions, Spotlight, and Mail smart features to parse text. Not present in all macOS 26 configurations; skipped gracefully if absent. Disable: launchctl bootout. Restore: bootstrap. Impact: NLP text analysis stopped."
    "corespeechd|siri|launchctl|corespeechd (user) — User-domain Core Speech daemon; coordinates speech recognition requests from apps and Siri. Disable: launchctl bootout gui domain. Restore: bootstrap. Impact: App-level speech recognition disabled."
    "SiriSuggestionsBookkeeping|siri|launchctl|SiriSuggestionsBookkeepingService — Bookkeeps which Siri Suggestions were shown, tapped, or dismissed to tune future suggestions. Disable: launchctl bootout. Restore: bootstrap. Impact: Suggestion relevance tuning data not collected."
    "suggestd|siri|launchctl|suggestd — Indexes app usage patterns, contact interactions, and location visits to power Siri Suggestions and Spotlight results. Runs continuously. Disable: launchctl bootout. Restore: bootstrap. Impact: Siri Suggestions and Spotlight suggestions not personalised."
    "routined|siri|launchctl|routined — Learns your daily routine (wake time, commute, regular locations) to power Siri time- and location-based suggestions. Disable: launchctl bootout. Restore: bootstrap. Impact: Routine learning stopped; no location-triggered Siri prompts."
    "duetexpertd|siri|launchctl|duetexpertd — Duet Activity Scheduler expert daemon; runs ML models that predict when you will next use each app to pre-warm them. Disable: launchctl bootout. Restore: bootstrap. Impact: App pre-warming ML stopped; minor cold-launch time increase for rarely used apps."
    "ospredictiond|siri|launchctl|ospredictiond — OS-level prediction daemon; predicts which resources (files, network endpoints) will be needed and prefetches them. Disable: launchctl bootout. Restore: bootstrap. Impact: Prefetch predictions not generated; no measurable latency impact on a dev machine with fast NVMe."
    "siriactionsd|siri|launchctl|siriactionsd (VoiceShortcuts) — Manages Siri Shortcuts: stores shortcut definitions, handles shortcut invocation, and syncs shortcuts via iCloud. Disable: db write + bootout. Restore: db remove. Impact: Siri Shortcuts not available; Hey Siri shortcut phrases not invokable."
    "followupd|siri|launchctl|followupd — Follow Up daemon; surfaces contextual follow-up suggestions based on messages, emails, and calendar events (e.g. 'Reply to this message'). Disable: db write + bootout. Restore: db remove. Impact: Follow Up suggestions not shown in Spotlight or Lock Screen."
    "liveactivitiesd|siri|launchctl|liveactivitiesd — Live Activities daemon; manages Dynamic Island and Lock Screen live activity updates for apps that use the ActivityKit framework. Disable: db write + bootout. Restore: db remove. Impact: Live Activities not updated; Dynamic Island widgets static."
    "statusKitAgent|siri|launchctl|StatusKitAgent — Syncs Focus status and availability indicators across Apple devices via iCloud. Disable: db write + bootout. Restore: db remove. Impact: Focus status not shared across devices."
    "AppSSOAgent|siri|launchctl|AppSSOAgent — App Single Sign-On agent; manages enterprise SSO extensions that allow apps to authenticate via a corporate identity provider without entering credentials each time. Disable: db write + bootout. Restore: db remove. Impact: Enterprise SSO extensions not active; apps fall back to individual credential prompts. Safe to disable if no corporate SSO is configured."
    "AppSSODaemon|siri|launchctl|AppSSODaemon — System-domain counterpart to AppSSOAgent; handles privileged portions of the SSO extension protocol. Disable: db write + bootout system. Restore: db remove system. Impact: SSO daemon not running; pairs with AppSSOAgent disable."
    "protectedcloudkeysyncing|icloud|launchctl|ProtectedCloudKeySyncing — Syncs end-to-end encrypted iCloud Keychain items (passwords, credit cards, Wi-Fi passwords) to other Apple devices via the protected cloud storage channel. Disable: db write + bootout. Restore: db remove. Impact: iCloud Keychain sync stops; local keychain items remain intact."
    "siri_disabled|siri|defaults|Siri disabled in com.apple.assistant.support — Master preference key that disables the Siri feature at the application layer. Disable: defaults write SiriEnabled=false. Restore: defaults write SiriEnabled=true. Impact: Siri toggle shown as off in System Settings; Siri shortcut unregistered."
    "siri_voice_feedback|siri|defaults|VoiceTriggerUserEnabled=false in com.apple.Siri — Disables the 'Hey Siri' always-on microphone wake-word listener. Disable: defaults write false. Restore: defaults delete. Impact: Microphone not polled continuously for wake word."
    # ── icloud ───────────────────────────────────────────────────────────────
    "bird|icloud|launchctl|bird — iCloud Drive daemon; syncs the ~/Library/CloudStorage and ~/Desktop/Documents folders to iCloud. Maintains a persistent connection. Disable: launchctl bootout. Restore: bootstrap. Impact: iCloud Drive sync stops; local files remain untouched."
    "cloudd_user|icloud|launchctl|cloudd (user domain) — CloudKit user-domain daemon; handles app-level iCloud database sync (Notes, Reminders, third-party apps using CloudKit). Disable: launchctl bootout gui domain. Restore: bootstrap. Impact: CloudKit app sync stops."
    "cloudphotod|icloud|launchctl|cloudphotod — iCloud Photos daemon; uploads new photos and downloads iCloud Photo Library changes. Disable: launchctl bootout. Restore: bootstrap. Impact: iCloud Photos sync stops."
    "cloudsettingssyncagent|icloud|launchctl|cloudsettingssyncagent — Syncs System Settings preferences (wallpaper, accessibility, keyboard shortcuts) to iCloud so they replicate to other Apple devices. Disable: launchctl bootout. Restore: bootstrap. Impact: Preference changes stay local only."
    "iCloudNotificationAgent|icloud|launchctl|iCloudNotificationAgent — Receives push notifications from iCloud services (Drive changes, shared album updates, etc.). Disable: launchctl bootout. Restore: bootstrap. Impact: iCloud push notifications not delivered."
    "syncdefaultsd|icloud|launchctl|syncdefaultsd — Syncs NSUserDefaults preference keys flagged for iCloud sync by apps that use the iCloud key-value store API. Disable: launchctl bootout. Restore: bootstrap. Impact: App preference sync via iCloud KV store stops."
    "cmfsyncagent|icloud|launchctl|cmfsyncagent — Communications Filter Sync agent; syncs call and message filter rules (spam filters) via iCloud across devices. Disable: launchctl bootout. Restore: bootstrap. Impact: Cross-device message filter rules not synced."
    "accountsd|icloud|launchctl|accountsd — Accounts framework daemon; manages Apple ID, iCloud, Google, Exchange, and other account credentials. Disabling stops background account refresh for all configured accounts. Disable: launchctl bootout. Restore: bootstrap. Impact: Background account sync stops; accounts remain configured but do not auto-refresh."
    "appleaccountd|icloud|launchctl|appleaccountd — Apple Account daemon (macOS 15+); handles Apple ID authentication tokens and session refresh for iCloud services. Disable: launchctl bootout. Restore: bootstrap. Impact: iCloud authentication tokens not refreshed; iCloud services effectively offline."
    "icloud_drive_defaults|icloud|defaults|NSDocumentSaveNewDocumentsToCloud=false — Prevents new documents created in TextEdit, Pages, Numbers etc. from defaulting to iCloud Drive as the save location. Disable: defaults write false. Restore: defaults write true. Impact: Save dialogs default to local disk instead of iCloud."
    # ── media ─────────────────────────────────────────────────────────────────
    "itunescloudd|media|launchctl|itunescloudd — iTunes Match / Apple Music cloud library daemon; keeps your local music library in sync with iCloud Music Library. Disable: launchctl bootout. Restore: bootstrap. Impact: Apple Music library sync stops; downloaded tracks remain."
    "AMPDeviceDiscoveryAgent|media|launchctl|AMPDeviceDiscoveryAgent — Scans for Apple media devices (Apple TV, HomePod, AirPlay targets) on the local network. Disable: launchctl bootout. Restore: bootstrap. Impact: Apple media device discovery stops; AirPlay target list empty."
    "AirPlayUIAgent|media|launchctl|AirPlayUIAgent — Manages the AirPlay status bar icon and receiver selection UI. Disable: launchctl bootout. Restore: bootstrap. Impact: AirPlay menu bar item removed; AirPlay still works if re-enabled."
    "sharingd|media|launchctl|sharingd — AirDrop, Bluetooth sharing, Optical disc sharing, and remote CD/DVD service daemon. Disable: launchctl bootout. Restore: bootstrap. Impact: AirDrop stops working; machine no longer visible for AirDrop transfers."
    "airdrop_defaults|media|defaults|DisableAirDrop=true in com.apple.NetworkBrowser — Preference-layer AirDrop disable; hides AirDrop from Finder sidebar and disables discoverability independently of sharingd. Disable: defaults write true. Restore: defaults write false. Impact: AirDrop hidden from Finder and not advertised via mDNS."
    "handoff_defaults|media|defaults|ActivityAdvertisingAllowed=false + ActivityReceivingAllowed=false — Disables Handoff/Continuity at the preference layer; stops the Bluetooth LE advertisements that make your open apps visible on nearby Apple devices. Disable: defaults write false on both keys. Restore: defaults write true. Impact: Handoff suggestions not shown on iPhone/iPad; cross-device clipboard not active."
    "ContinuityCaptureAgent|media|launchctl|ContinuityCaptureAgent — Enables Continuity Camera (use iPhone as a Mac webcam). Maintains a persistent Bluetooth and WiFi pairing with nearby iPhones. Disable: launchctl bootout. Restore: bootstrap. Impact: iPhone cannot be used as a webcam; Continuity Camera option not shown in video apps."
    "mediaremoteagent|media|launchctl|mediaremoteagent — User-domain Now Playing / media remote agent; exposes current playback state (track name, art, position) to Control Centre and remote control devices. Disable: launchctl bootout. Restore: bootstrap. Impact: Now Playing widget and media key remote control from external devices stop."
    "replayd|media|launchctl|replayd — ReplayKit daemon; manages screen and audio recording caches used by ReplayKit game/app replay features. Disable: launchctl bootout. Restore: bootstrap. Impact: ReplayKit replay buffer not maintained; screen recording via QuickTime still works."
    "BTServer_cloudpairing|media|launchctl|BTServer cloudpairing agent — Manages Bluetooth cloud pairing so Bluetooth devices (AirPods, Magic Keyboard) pair automatically with all your Apple devices via iCloud. Disable: launchctl bootout. Restore: bootstrap. Impact: Bluetooth accessories do not auto-pair across Apple devices."
    # ── apple_intel ──────────────────────────────────────────────────────────
    "generativeexperiencesd|apple_intel|launchctl|generativeexperiencesd — Apple Intelligence generative experiences runtime; manages Writing Tools, image generation, and other generative AI features introduced in macOS 15. Disable: launchctl bootout. Restore: bootstrap. Impact: Apple Intelligence generative features unavailable."
    "intelligencecontextd|apple_intel|launchctl|intelligencecontextd — Intelligence Flow Context daemon; gathers on-device context (open documents, current app, recent actions) to supply to Apple Intelligence models for personalised responses. Disable: launchctl bootout. Restore: bootstrap. Impact: Apple Intelligence has no contextual awareness."
    "IntelligencePlatformComputeService|apple_intel|launchctl|intelligenceplatformd + intelligencetasksd — Apple Intelligence platform daemon and tasks engine; dispatches inference requests to Neural Engine/GPU and manages the task queue for Writing Tools, summaries, and generative features. Disable: db write + bootout both labels. Restore: db remove. Impact: Apple Intelligence on-device inference stopped."
    "privatecloudcomputed|apple_intel|launchctl|privatecloudcomputed — Private Cloud Compute daemon; routes Apple Intelligence requests that exceed on-device capability to Apple's privacy-preserving cloud inference servers. Disable: launchctl bootout. Restore: bootstrap. Impact: Cloud AI inference requests not sent; no data leaves the device via this path."
    "ModelCatalogAgent|apple_intel|launchctl|ModelCatalogAgent — User-domain agent that checks for updated Apple Intelligence model packages and downloads them from Apple's CDN in the background. Disable: launchctl bootout. Restore: bootstrap. Impact: Apple Intelligence model updates not downloaded."
    "modelcatalogd|apple_intel|launchctl|modelcatalogd — System daemon that manages the on-disk catalogue of installed Apple Intelligence model bundles and their metadata. Disable: launchctl bootout. Restore: bootstrap. Impact: Model catalogue not maintained; pairs with ModelCatalogAgent disable."
    "AppleIntelligenceReporting|apple_intel|launchctl|AppleIntelligenceReportingProcessingService — Processes and aggregates Apple Intelligence usage events for telemetry reporting to Apple. Disable: launchctl bootout. Restore: bootstrap. Impact: Apple Intelligence usage data not reported."
    # ── appstore ─────────────────────────────────────────────────────────────
    "promotedcontentd|appstore|launchctl|promotedcontentd — App Store promoted/advertised content daemon; fetches personalised app and in-app purchase ads from Apple's ad platform and stores them for display in App Store search results. Disable: launchctl bootout. Restore: bootstrap. Impact: App Store ad slots empty; no ad targeting requests made."
    "adprivacyd|appstore|launchctl|adprivacyd — Ad privacy daemon (SKAdNetwork / Apple Ads attribution); manages the privacy-preserving ad click attribution pipeline used by App Store ads. Disable: launchctl bootout. Restore: bootstrap. Impact: Ad attribution pipeline stops; no ad measurement data sent to Apple."
    "amsengagementd|appstore|launchctl|amsengagementd — Apple Media Services engagement daemon; tracks which App Store features you interact with (banners, editorial content, 'Today' tab) to personalise the storefront. Disable: launchctl bootout. Restore: bootstrap. Impact: Storefront engagement data not collected."
    "amsondevicestoraged|appstore|launchctl|amsondevicestoraged — Stores Apple Media Services engagement data on-device before it is uploaded. Acts as a local buffer for amsengagementd. Disable: launchctl bootout. Restore: bootstrap. Impact: Engagement data buffer not maintained; pairs with amsengagementd disable."
    "amsaccountsd|appstore|launchctl|amsaccountsd — Apple Media Services accounts daemon; manages authentication tokens for Apple Music, TV+, Arcade, and App Store purchases. Disable: launchctl bootout. Restore: bootstrap. Impact: Media service purchases and subscriptions require manual re-authentication."
    "appstoreagent|appstore|launchctl|appstoreagent — App Store user-domain agent; handles app installation, update checks, receipt validation, and in-app purchase UI on behalf of App Store. Disable: launchctl bootout. Restore: bootstrap. Impact: App Store UI still opens but app updates and purchases require manual initiation."
    "commerce|appstore|launchctl|commerce (CommerceKit) — Manages App Store purchase receipts, subscription state, and StoreKit transaction validation. Disable: launchctl bootout. Restore: bootstrap. Impact: StoreKit receipt validation and subscription status checks stop in the background."
    "triald|appstore|launchctl|triald (user domain) — Apple A/B feature trial daemon; enrolls the machine in feature experiments Apple runs on its user base and activates trial feature flags. Disable: launchctl bootout. Restore: bootstrap. Impact: Machine not enrolled in Apple A/B experiments."
    "triald_system|appstore|launchctl|triald (system domain) — System-domain counterpart to triald; applies feature trial flags at the system level for OS-wide experiments. Disable: launchctl bootout system. Restore: bootstrap system. Impact: System-level feature trials not applied."
    "TrialArchivingService|appstore|launchctl|TrialArchivingService — Archives trial participation data and outcomes for upload to Apple's experiment analytics platform. Disable: launchctl bootout. Restore: bootstrap. Impact: Trial outcome data not archived or uploaded."
    "SetStoreUpdateService|appstore|launchctl|SetStoreUpdateService (CascadeSets) — Fetches updates to curated App Store collection sets (editorial lists, top charts) in the background. Disable: launchctl bootout. Restore: bootstrap. Impact: App Store editorial collections not pre-fetched."
    # ── mail ─────────────────────────────────────────────────────────────────
    "maild|mail|launchctl|maild — Mail app background daemon; maintains IMAP/Exchange connections, downloads new messages, and triggers Mail notifications even when the Mail app is not open. Disable: launchctl bootout. Restore: bootstrap. Impact: No background email fetching; Mail still works when opened manually."
    "calaccessd|mail|launchctl|calaccessd — Calendar data access daemon; maintains CalDAV and Exchange calendar sync in the background. Not present as a standalone label in all macOS 26 builds; handled gracefully. Disable: launchctl bootout. Restore: bootstrap. Impact: Calendar events not synced in the background."
    "contactsd|mail|launchctl|contactsd — Contacts framework daemon; syncs CardDAV, Exchange, and iCloud contacts in the background. Disable: launchctl bootout. Restore: bootstrap. Impact: Contacts not synced in the background; contact data remains in local store."
    "remindd|mail|launchctl|remindd — Reminders daemon; maintains sync with iCloud Reminders and fires local notification alerts for due reminders. Disable: launchctl bootout. Restore: bootstrap. Impact: Reminder notifications not fired; iCloud Reminders not synced."
    "dataaccessd|mail|launchctl|dataaccessd — Data Access daemon; the central broker for Mail, Calendar, Contacts, and Notes account data access. Bridges account credentials to app-level data requests. Disable: launchctl bootout. Restore: bootstrap. Impact: Background data access for all four apps stops."
    "imagent|mail|launchctl|imagent — iMessage agent; maintains the iMessage/SMS relay connection, handles message sync, and fires message notifications. Disable: launchctl bootout. Restore: bootstrap. Impact: iMessage and SMS relay stop."
    "callservicesd|mail|launchctl|callservicesd — Call services daemon; handles iPhone call relay (Continuity Phone), FaceTime call setup, and CallKit integrations. Disable: launchctl bootout. Restore: bootstrap. Impact: iPhone call relay and FaceTime stop."
    "communicationtrustd|mail|launchctl|communicationtrustd — Evaluates whether incoming calls and messages are from known contacts or potential spam; feeds Communication Safety features. Disable: launchctl bootout. Restore: bootstrap. Impact: Communication spam/safety scoring stops."
    "contactsdonationagent|mail|launchctl|contactsdonationagent — Donates contact interaction events (who you called, messaged, emailed) to Siri Suggestions so frequently-contacted people are surfaced proactively. Disable: launchctl bootout. Restore: bootstrap. Impact: Contact-based Siri Suggestions not personalised."
    # ── social ────────────────────────────────────────────────────────────────
    "mapssyncd|social|launchctl|mapssyncd — Syncs Maps favourites, guides, and recent searches to iCloud so they appear on all Apple devices. Disable: launchctl bootout. Restore: bootstrap. Impact: Maps data not synced across devices."
    "weatherd|social|launchctl|weatherd — Background Weather data daemon; fetches forecast data from Apple's weather service for the Weather app and widgets even when neither is visible. Disable: launchctl bootout. Restore: bootstrap. Impact: Weather widget shows stale data; Weather app fetches fresh data on open."
    "financed|social|launchctl|financed (FinanceKit) — FinanceKit daemon; syncs financial data from Apple Pay, Wallet transactions, and bank feeds for the Stocks and Wallet apps. Disable: launchctl bootout. Restore: bootstrap. Impact: Financial data not synced in background."
    "StocksKitService|social|launchctl|StocksKitService — Fetches stock quotes and financial news for the Stocks app and Stocks widget. Disable: launchctl bootout. Restore: bootstrap. Impact: Stocks widget shows stale data; Stocks app fetches on open."
    "homeeventsd|social|launchctl|homeeventsd — HomeKit events daemon; processes home automation trigger events from HomeKit accessories. Not present as a standalone label in macOS 26; handled gracefully. Disable: launchctl bootout. Restore: bootstrap. Impact: HomeKit automations not triggered in the background."
    "homed|social|launchctl|homed — HomeKit daemon; maintains the Home database, communicates with HomeKit accessories over the network, and handles Matter/Thread device pairing. Disable: launchctl bootout. Restore: bootstrap. Impact: HomeKit entirely stops; accessories not reachable from this Mac."
    "homeenergyd|social|launchctl|homeenergyd — Home Energy daemon (iOS compatibility layer); fetches and stores home energy usage data for HomeKit energy-reporting accessories. Disable: launchctl bootout. Restore: bootstrap. Impact: Home energy reporting data not fetched."
    "FindMyMacd|social|launchctl|findmymacd — Find My Mac daemon; maintains the encrypted location beacon broadcast and handles remote lock/erase commands from iCloud. Disable: launchctl bootout system. Restore: bootstrap system. Impact: This Mac no longer visible or controllable via Find My."
    "findmybeaconingd|social|launchctl|findmybeaconingd — Broadcasts Bluetooth LE beacons that allow nearby Apple devices to relay this machine's location when it is offline. Disable: launchctl bootout system. Restore: bootstrap system. Impact: Offline finding via the Find My network stops."
    "findmylocateagent|social|launchctl|findmylocateagent — User agent that reports location to Find My when the system is awake. Disable: launchctl bootout. Restore: bootstrap. Impact: Online location reporting to Find My stops."
    "searchpartyd|social|launchctl|searchpartyd — System-domain Find My search party daemon; coordinates encrypted Find My location beacon relaying. Disable: launchctl bootout system. Restore: bootstrap system. Impact: Machine does not participate in relaying Find My beacons for other lost devices."
    "searchpartyuseragent|social|launchctl|searchpartyuseragent — User-domain Find My search party agent. Disable: launchctl bootout. Restore: bootstrap. Impact: Find My search party user-space participation stops."
    "sociallayerd|social|launchctl|sociallayerd — Social layer daemon; aggregates contact interaction data and social graph signals to surface contextually relevant contacts in Siri and Spotlight. Disable: launchctl bootout. Restore: bootstrap. Impact: Social-graph-based contact suggestions not generated."
    "ndoagent|social|launchctl|ndoagent (NewDeviceOutreach) — Detects when new Apple devices are nearby and triggers 'Quick Start' and accessory setup prompts. Disable: launchctl bootout. Restore: bootstrap. Impact: New device setup suggestions not shown."
    "photolibraryd|social|launchctl|photolibraryd — Photos library daemon; indexes the local photo library and serves photo data to Photos, iMessage, Spotlight, and other apps. Disable: launchctl bootout. Restore: bootstrap. Impact: Photos library not indexed in the background; Photos app re-indexes on open. Only disable if Photos is not used."
    "photoanalysisd|social|launchctl|photoanalysisd — Runs ML analysis on photos to identify faces, scenes, objects, and text for the People/Places/Memories features. High CPU usage after library changes. Disable: launchctl bootout. Restore: bootstrap. Impact: Photo ML analysis stops; People, Places, and Memories not updated."
    "mediaanalysisd|social|launchctl|mediaanalysisd — Runs ML analysis on videos for scene detection and visual search. Complement to photoanalysisd for video content. Disable: launchctl bootout. Restore: bootstrap. Impact: Video content ML analysis stops."
    # ── gaming ────────────────────────────────────────────────────────────────
    "gamecontrolleragentd|gaming|launchctl|gamecontrolleragentd — User-domain game controller agent; monitors for connected game controllers and publishes them to the GCController framework. Disable: launchctl bootout. Restore: bootstrap. Impact: Game controllers not discovered by apps using GameController framework."
    "gamecontrollerd|gaming|launchctl|gamecontrollerd — System-domain game controller daemon; handles HID-level controller input routing. Disable: launchctl bootout system. Restore: bootstrap system. Impact: Game controller input not routed to apps."
    "gamepolicyd|gaming|launchctl|gamepolicyd — Manages Game Mode policy; determines when a game is the primary focus and applies CPU/GPU priority boosts. Disable: launchctl bootout system. Restore: bootstrap system. Impact: Game Mode not activated for any app."
    "GamePolicyAgent|gaming|launchctl|GamePolicyAgent — User-domain counterpart to gamepolicyd; communicates Game Mode status to apps via the GKGameCenterViewController API. Disable: db write + bootout. Restore: db remove. Impact: Game Mode UI not shown to apps."
    "GameController_agent|gaming|launchctl|GameController_agent — Duplicate GameController agent label (com.apple.GameController.gamecontrolleragentd). Covers both label variants present on macOS 26. Disable: launchctl bootout. Restore: bootstrap. Impact: Controller discovery stops."
    # ── mdm ──────────────────────────────────────────────────────────────────
    "remotemanagementd|mdm|launchctl|remotemanagementd — Remote Management daemon; implements the MDM protocol, receives management commands from an MDM server, and applies configuration profiles. Disable: launchctl bootout system. Restore: bootstrap system. Impact: MDM commands not received or processed. Only disable if this machine is not enrolled in MDM."
    "RemoteManagementAgent|mdm|launchctl|RemoteManagementAgent — User-domain MDM agent; applies user-scoped MDM payloads (email accounts, VPN profiles, per-user restrictions) delivered by remotemanagementd. Disable: launchctl bootout. Restore: bootstrap. Impact: User-scoped MDM payloads not applied."
    "ManagedSettingsAgent|mdm|launchctl|ManagedSettingsAgent — Enforces managed preference restrictions set by MDM (screen time limits, content filters, app restrictions). Disable: launchctl bootout. Restore: bootstrap. Impact: Managed preference restrictions not enforced."
    "managedappdistributiond|mdm|launchctl|managedappdistributiond — System daemon for MDM-managed app distribution; handles VPP app assignment and installation commands. Disable: launchctl bootout system. Restore: bootstrap system. Impact: MDM-pushed app installs not processed."
    "managedappdistributionagent|mdm|launchctl|managedappdistributionagent — User-domain counterpart to managedappdistributiond; handles the user-visible parts of MDM app distribution. Disable: launchctl bootout. Restore: bootstrap. Impact: User-facing MDM app distribution stops."
    # ── updates ──────────────────────────────────────────────────────────────
    "softwareupdated|updates|launchctl|softwareupdated — Background software update daemon; periodically checks Apple's update servers, downloads update packages, and notifies users. Disable: launchctl bootout system (both com.apple.softwareupdated and com.apple.mobile.softwareupdated). Restore: bootstrap. Impact: Automatic update checks and downloads stop; updates still work manually via System Settings."
    "SoftwareUpdateNotificationManager|updates|launchctl|SoftwareUpdateNotificationManager — Presents the 'Update Available' notification banner and badge. Disable: launchctl bootout. Restore: bootstrap. Impact: Update notification banners not shown; pairs with softwareupdated disable."
    "autoupdate_defaults|updates|defaults|AutomaticCheckEnabled=false + AutomaticDownload=false + AutoUpdate=false in com.apple.SoftwareUpdate — Preference-layer software update disables: stops the update check scheduler from re-enabling the daemon. Disable: defaults write all three false. Restore: defaults write all three true. Impact: Even if softwareupdated restarts after an OS update, preference flags prevent auto-check and auto-download."
    "assetsubscriptiond|updates|launchctl|assetsubscriptiond — Subscribes to Apple asset delivery feeds (Siri voices, system fonts, AR assets, ML model components) and downloads them when the device is idle. Disable: launchctl bootout. Restore: bootstrap. Impact: Optional system asset downloads stop; existing assets remain; new feature assets not pre-fetched."
    "jetpackassetd|updates|launchctl|jetpackassetd (JetCore) — Downloads and caches JetEngine precompiled shader and ML model assets used to accelerate app launch on Apple Silicon. Disable: launchctl bootout. Restore: bootstrap. Impact: JetEngine asset prefetch stops; existing cached assets still used; minor first-launch latency for affected apps."
    "mobileassetd|updates|launchctl|mobileassetd — Core asset delivery daemon that backs assetsubscriptiond; manages the download queue, caching, and integrity verification of all Apple asset packages. Disable: launchctl bootout system. Restore: bootstrap system. Impact: All Apple background asset delivery stops."
)

TOTAL_ITEMS=${#DISABLE_LIST[@]}

# ---------------------------------------------------------------------------
# Build work list
# ---------------------------------------------------------------------------
build_work_list() {
    WORK_LIST=()
    local idx=0
    for entry in "${DISABLE_LIST[@]}"; do
        idx=$((idx + 1))
        local key group method desc
        key=$(    echo "$entry" | cut -d'|' -f1)
        group=$(  echo "$entry" | cut -d'|' -f2)
        method=$( echo "$entry" | cut -d'|' -f3)
        desc=$(   echo "$entry" | cut -d'|' -f4)

        if [ -n "$ITEM_FILTER" ]; then
            if ! echo ",$ITEM_FILTER," | grep -qF ",$key,"; then continue; fi
        fi
        if [ -n "$GROUP_FILTER" ]; then
            if ! echo ",$GROUP_FILTER," | grep -qF ",$group,"; then continue; fi
        fi
        if [ -n "$SKIP_FILTER" ]; then
            if echo ",$SKIP_FILTER," | grep -qF ",$key,";   then continue; fi
            if echo ",$SKIP_FILTER," | grep -qF ",$group,"; then continue; fi
        fi

        WORK_LIST+=("$idx|$key|$group|$method|$desc")
    done
}

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if [ "$LIST_ONLY" = true ]; then
    header "DISABLE — $TOTAL_ITEMS items across 11 groups"
    current_group=""
    idx=0
    for entry in "${DISABLE_LIST[@]}"; do
        idx=$((idx + 1))
        key=$(    echo "$entry" | cut -d'|' -f1)
        group=$(  echo "$entry" | cut -d'|' -f2)
        method=$( echo "$entry" | cut -d'|' -f3)
        desc=$(   echo "$entry" | cut -d'|' -f4)
        # Truncate description to first sentence for display
        short=$(echo "$desc" | cut -d'—' -f1 | sed 's/[[:space:]]*$//')
        if [ "$group" != "$current_group" ]; then
            echo ""
            echo "  ── $group ──"
            current_group="$group"
        fi
        printf "  %3d  %-42s [%-11s]  %s\n" "$idx" "$key" "$method" "$short"
    done
    echo ""
    echo "  Total: $TOTAL_ITEMS"
    echo "  Usage: sudo ./disable.sh --yes [--restore] [--group <group>]"
    exit 0
fi

header "DISABLE — macOS $(sw_vers -productVersion)"
log "Log:     $LOG"
log "Dry run: $DRY_RUN"
log "Mode:    $([ "$RESTORE_MODE" = true ] && echo 'RESTORE (re-enable to macOS defaults)' || echo 'DISABLE')"
log "Yes all: $YES_ALL"
log "User:    $REAL_USER (home: $REAL_HOME)"

build_work_list
log "Items to process: ${#WORK_LIST[@]} of $TOTAL_ITEMS"

# ---------------------------------------------------------------------------
# Confirmation engine
# Returns via global ACTION: "disable" | "restore" | "skip"
# ---------------------------------------------------------------------------
_accept_all=false
ACTION="disable"

_confirm_item() {
    local number="$1" key="$2" method="$3" desc="$4" current="$5" \
          mac_default="$6" disabled_val="$7"

    # In --restore mode the default action flips to restore
    local default_action; default_action=$([ "$RESTORE_MODE" = true ] && echo "restore" || echo "disable")

    if [ "$YES_ALL" = true ] || [ "$_accept_all" = true ]; then
        ACTION="$default_action"; return
    fi

    echo ""
    sep
    printf "  [%d/%d] %s\n"   "$number" "${#WORK_LIST[@]}" "$key"
    printf "  Group:    %s\n" "$_ITEM_GROUP"
    printf "  Method:   %s\n" "$method"
    printf "  Desc:     %s\n" "$desc"
    printf "  Current:  %s\n" "${current:-(not set)}"
    printf "  Default:  %s\n" "${mac_default:-(system default)}"
    printf "  Disabled: %s\n" "${disabled_val:-(service stopped)}"
    printf "  Action? [d=disable / r=restore / n=skip / a=all / q=quit]: "

    if [ -t 0 ]; then
        local _old_stty; _old_stty=$(stty -g </dev/tty 2>/dev/null)
        stty -icanon min 0 time 0 </dev/tty 2>/dev/null
        while IFS= read -r -t 0 -n 1 _ </dev/tty 2>/dev/null; do :; done
        stty "$_old_stty" </dev/tty 2>/dev/null
    fi

    local ans ans_lower
    IFS= read -r ans < /dev/tty
    ans=$(printf '%s' "$ans" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    ans_lower=$(echo "$ans" | tr '[:upper:]' '[:lower:]')

    case "$ans_lower" in
        d|disable|y|yes|"")  ACTION="disable" ;;
        r|restore)           ACTION="restore" ;;
        n|no)                ACTION="skip" ;;
        a|all)               _accept_all=true; ACTION="$default_action" ;;
        q|quit|exit)
            log "Quit at item $number ($key)."
            exit 0 ;;
        *)
            warn "Unrecognised input '${ans}' — skipping (valid: d/r/n/a/q)"
            ACTION="skip" ;;
    esac
}

_dry_item() {
    local number="$1" key="$2" method="$3" current="$4" mac_default="$5" disabled_val="$6"
    printf "  [%3d/%d] %-42s [%s]  current=%-25s default=%-25s disabled=%s\n" \
        "$number" "${#WORK_LIST[@]}" "$key" "$method" \
        "${current:-(not set)}" "${mac_default:-(sys default)}" "${disabled_val:-(stopped)}"
}

# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

# In-memory accumulators for disable database writes.
# We collect all labels during the run and flush once at the end,
# rather than calling PlistBuddy once per label (which caused 200+ sudo prompts).
# Format: "domain_type:label"  e.g. "gui:com.apple.assistantd"
_DB_DISABLE_QUEUE=()
_DB_ENABLE_QUEUE=()

# _db_queue_disable DOMAIN_TYPE LABEL  — queue for bulk write at flush time
_db_queue_disable() { _DB_DISABLE_QUEUE+=("$1:$2"); }

# _db_queue_enable DOMAIN_TYPE LABEL  — queue for bulk delete at flush time
_db_queue_enable()  { _DB_ENABLE_QUEUE+=("$1:$2"); }

# _db_flush — called once after all items are processed.
# Reads both db plists once, applies all queued changes, writes back once each.
# The script already runs as root (sudo ./disable.sh) so no extra sudo prompts.
_db_flush() {
    local GUI_DB="/var/db/com.apple.xpc.launchd/disabled.${REAL_UID}.plist"
    local SYS_DB="/var/db/com.apple.xpc.launchd/disabled.plist"

    # Temporarily suspend nounset so empty arrays don't trigger unbound errors.
    # Both arrays are always initialised to () above; they are never truly unbound.
    set +u
    local ndis=${#_DB_DISABLE_QUEUE[@]}
    local nena=${#_DB_ENABLE_QUEUE[@]}
    set -u

    if [ "$ndis" -eq 0 ] && [ "$nena" -eq 0 ]; then
        return 0
    fi

    log "Flushing disable database ($ndis disable, $nena restore)..."

    # Write each label individually — PlistBuddy crashes on 200+ -c args at once.
    # Script already runs as root so no extra sudo prompts.
    local gui_ok=0 sys_ok=0

    set +u
    for entry in "${_DB_DISABLE_QUEUE[@]}"; do
        set -u
        local dt="${entry%%:*}" label="${entry#*:}"
        if [ "$dt" = "gui" ]; then
            /usr/libexec/PlistBuddy -c "Add :${label} bool true" "$GUI_DB" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Set :${label} true"       "$GUI_DB" 2>/dev/null || true
            gui_ok=1
        else
            /usr/libexec/PlistBuddy -c "Add :${label} bool true" "$SYS_DB" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Set :${label} true"       "$SYS_DB" 2>/dev/null || true
            sys_ok=1
        fi
    done
    set -u

    set +u
    for entry in "${_DB_ENABLE_QUEUE[@]}"; do
        set -u
        local dt="${entry%%:*}" label="${entry#*:}"
        if [ "$dt" = "gui" ]; then
            /usr/libexec/PlistBuddy -c "Delete :${label}" "$GUI_DB" 2>/dev/null || true
            gui_ok=1
        else
            /usr/libexec/PlistBuddy -c "Delete :${label}" "$SYS_DB" 2>/dev/null || true
            sys_ok=1
        fi
    done
    set -u

    [ "$gui_ok" -eq 1 ] && ok "gui disable db written ($GUI_DB)" || true
    [ "$sys_ok" -eq 1 ] && ok "system disable db written ($SYS_DB)" || true
}

# _db_check_disabled DOMAIN_TYPE LABEL — returns "true" or "" using cached db reads
# Cache is populated once on first call per db file to avoid repeated file reads.
_GUI_DB_CACHE=""
_SYS_DB_CACHE=""
_db_check_disabled() {
    local domain_type="$1" label="$2"
    if [ "$domain_type" = "gui" ]; then
        [ -z "$_GUI_DB_CACHE" ] && \
            _GUI_DB_CACHE=$(plutil -p "/var/db/com.apple.xpc.launchd/disabled.${REAL_UID}.plist" 2>/dev/null || echo "")
        echo "$_GUI_DB_CACHE" | grep -q "\"${label}\" => 1" && echo "true" || echo ""
    else
        [ -z "$_SYS_DB_CACHE" ] && \
            _SYS_DB_CACHE=$(plutil -p "/var/db/com.apple.xpc.launchd/disabled.plist" 2>/dev/null || echo "")
        echo "$_SYS_DB_CACHE" | grep -q "\"${label}\" => 1" && echo "true" || echo ""
    fi
}

# _lctl KEY DOMAIN_TYPE LABEL
#   DOMAIN_TYPE: "gui" (per-user) | "system" (root LaunchDaemon)
#   disable branch:
#     1. Queue label into in-memory disable db (flushed once at end of run)
#     2. launchctl bootout to stop any currently running instance immediately
#   restore branch:
#     1. Queue label removal from disable db
#     2. launchctl enable + bootstrap to restart now
_lctl() {
    local key="$1" domain_type="$2" label="$3"
    local mac_default="enabled (macOS default)" disabled_val="stopped + disabled"

    local domain_path
    [ "$domain_type" = "gui" ] && domain_path="gui/$REAL_UID" || domain_path="system"

    # Detect current state — handle both legacy tabular and macOS 26 JSON output
    local current
    if launchctl list "$label" > /dev/null 2>&1; then
        local _raw; _raw=$(launchctl list "$label" 2>/dev/null)
        local _pid; _pid=$(echo "$_raw" | grep -o '"PID"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')
        [ -z "$_pid" ] && _pid=$(echo "$_raw" | awk 'NR==1 && $1 ~ /^[0-9]+$/ {print $1}')
        [ -n "$_pid" ] && [ "$_pid" != "-" ] && current="running (PID $_pid)" || current="loaded (not running)"
    else
        local _in_db; _in_db=$(_db_check_disabled "$domain_type" "$label")
        [ "$_in_db" = "true" ] && current="already disabled (db)" || current="not loaded"
    fi

    [ "$DRY_RUN" = true ] && { _dry_item "$_ITEM_NUM" "$key" "launchctl" "$current" "$mac_default" "$disabled_val"; return; }
    _confirm_item "$_ITEM_NUM" "$key" "launchctl" "${_ITEM_DESC}" "$current" "$mac_default" "$disabled_val"

    case "$ACTION" in
        disable)
            _db_queue_disable "$domain_type" "$label"
            launchctl bootout "$domain_path/$label" 2>/dev/null || true
            ok "$key — queued for db disable + bootout ($label)"
            ;;
        restore)
            _db_queue_enable "$domain_type" "$label"
            launchctl enable "$domain_path/$label" 2>/dev/null || true
            local _plist
            _plist=$(find /System/Library/LaunchAgents /System/Library/LaunchDaemons \
                         /Library/LaunchAgents /Library/LaunchDaemons \
                    -name "${label}.plist" 2>/dev/null | head -1)
            [ -n "$_plist" ] && launchctl bootstrap "$domain_path" "$_plist" 2>/dev/null || true
            ok "$key — queued for db restore + bootstrap ($label)"
            ;;
        skip) log "$key — skipped" ;;
    esac
}

# _dfw_disable KEY DOMAIN PLIST_KEY TYPE MAC_DEFAULT DISABLED_VAL
#   Writes a defaults key to disable a feature, restores on 'r'.
_dfw_disable() {
    local key="$1" domain="$2" plist_key="$3" type="$4" mac_default="$5" disabled_val="$6"

    local current; current=$(dfw read "$domain" "$plist_key" 2>/dev/null || echo "(not set)")
    [ "$DRY_RUN" = true ] && { _dry_item "$_ITEM_NUM" "$key" "defaults" "$current" "$mac_default" "$disabled_val"; return; }
    _confirm_item "$_ITEM_NUM" "$key" "defaults" "${_ITEM_DESC}" "$current" "$mac_default" "$disabled_val"

    case "$ACTION" in
        disable)
            dfw write "$domain" "$plist_key" "$type" "$disabled_val"
            ok "$key — $domain $plist_key = $disabled_val"
            ;;
        restore)
            if [ -z "$mac_default" ] || [ "$mac_default" = "(not set)" ]; then
                dfw delete "$domain" "$plist_key" 2>/dev/null || true
                ok "$key — $domain $plist_key deleted (macOS default)"
            else
                dfw write "$domain" "$plist_key" "$type" "$mac_default"
                ok "$key — $domain $plist_key = $mac_default (macOS default)"
            fi
            ;;
        skip) log "$key — skipped" ;;
    esac
}

# _sudodfw_disable KEY PLIST_PATH PLIST_KEY TYPE MAC_DEFAULT DISABLED_VAL
#   Same as _dfw_disable but uses sudo defaults for system plists.
_sudodfw_disable() {
    local key="$1" plist="$2" plist_key="$3" type="$4" mac_default="$5" disabled_val="$6"

    local current; current=$(sudo defaults read "$plist" "$plist_key" 2>/dev/null || echo "(not set)")
    [ "$DRY_RUN" = true ] && { _dry_item "$_ITEM_NUM" "$key" "plist" "$current" "$mac_default" "$disabled_val"; return; }
    _confirm_item "$_ITEM_NUM" "$key" "plist" "${_ITEM_DESC}" "$current" "$mac_default" "$disabled_val"

    case "$ACTION" in
        disable)
            sudo defaults write "$plist" "$plist_key" "$type" "$disabled_val"
            ok "$key — $plist_key = $disabled_val"
            ;;
        restore)
            if [ -z "$mac_default" ]; then
                sudo defaults delete "$plist" "$plist_key" 2>/dev/null || true
                ok "$key — $plist_key deleted (macOS default)"
            else
                sudo defaults write "$plist" "$plist_key" "$type" "$mac_default"
                ok "$key — $plist_key = $mac_default (macOS default)"
            fi
            ;;
        skip) log "$key — skipped" ;;
    esac
}

# ---------------------------------------------------------------------------
# APPLY FUNCTIONS — one per key
# $_ITEM_NUM and $_ITEM_DESC are set by the dispatch loop before calling.
# ---------------------------------------------------------------------------

# ── TELEMETRY ───────────────────────────────────────────────────────────────

apply_analyticsagent() {
    _lctl "analyticsagent" "gui" "com.apple.analyticsagent"
}

apply_analyticsd() {
    _lctl "analyticsd" "system" "com.apple.analyticsd"
}

apply_biomed() {
    _lctl "biomed" "system" "com.apple.biomed"
}

apply_biomesyncd() {
    _lctl "biomesyncd" "system" "com.apple.biomesyncd"
}

apply_BiomeAgent() {
    _lctl "BiomeAgent" "gui" "com.apple.BiomeAgent"
}

apply_UsageTrackingAgent() {
    _lctl "UsageTrackingAgent" "gui" "com.apple.UsageTrackingAgent"
}

apply_inputanalyticsd() {
    _lctl "inputanalyticsd" "system" "com.apple.inputanalyticsd"
}

apply_wifianalyticsd() {
    _lctl "wifianalyticsd" "system" "com.apple.wifianalyticsd"
}

apply_audioanalyticsd() {
    _lctl "audioanalyticsd" "system" "com.apple.audioanalyticsd"
}

apply_historicalaudiod() {
    _lctl "historicalaudiod" "system" "com.apple.historicalaudiod"
}

apply_diagnosticsagent() {
    _lctl "diagnosticsagent" "gui" "com.apple.diagnostics_agent"
}

apply_diagnosticextensionsd() {
    _lctl "diagnosticextensionsd" "gui" "com.apple.diagnosticextensionsd"
}

apply_ReportCrash() {
    _lctl "ReportCrash" "gui" "com.apple.ReportCrash"
}

apply_osanalyticshelper() {
    _lctl "osanalyticshelper" "system" "com.apple.osanalytics.osanalyticshelper"
}

apply_ecosystemanalyticsd() {
    _lctl "ecosystemanalyticsd" "system" "com.apple.ecosystemanalyticsd"
}

apply_geoanalyticsd() {
    _lctl "geoanalyticsd" "gui" "com.apple.geoanalyticsd"
}

apply_tailspind() {
    _lctl "tailspind" "system" "com.apple.tailspind"
}

apply_rtcreportingd() {
    _lctl "rtcreportingd" "system" "com.apple.rtcreportingd"
}

apply_PerfPowerTelemetry() {
    _lctl "PerfPowerTelemetry" "system" \
        "com.apple.PerfPowerTelemetryClientRegistrationService"
}

apply_spotlightknowledged_importer() {
    _lctl "spotlightknowledged_importer" "gui" "com.apple.spotlightknowledged.importer"
}

apply_spotlightknowledged_updater() {
    _lctl "spotlightknowledged_updater" "gui" "com.apple.spotlightknowledged.updater"
}

apply_knowledge_agent() {
    _lctl "knowledge_agent" "gui" "com.apple.knowledge-agent"
}

apply_knowledgeconstructiond() {
    _lctl "knowledgeconstructiond" "gui" "com.apple.knowledgeconstructiond"
}

apply_CloudTelemetryService() {
    local label="com.apple.CloudTelemetry.CloudTelemetryService"
    # Multiple XPC instances share the same label; bootout handles all
    _lctl "CloudTelemetryService" "gui" "$label"
}

apply_analyticsagent_defaults() {
    _sudodfw_disable "analyticsagent_defaults" \
        "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" \
        "AutoSubmit" "-bool" "true" "false"
    # Also write the SoftwareUpdate-adjacent key
    _dfw_disable "analyticsagent_defaults_submitdi" \
        "com.apple.SubmitDiagInfo" "AutomaticCheckEnabled" "-bool" "true" "false"
}

apply_diag_autosend() {
    _sudodfw_disable "diag_autosend" \
        "/Library/Application Support/CrashReporter/DiagnosticMessagesHistory.plist" \
        "AutoSubmit" "-bool" "true" "false"
    _sudodfw_disable "diag_autosend_syspref" \
        "/Library/Preferences/com.apple.SubmitDiagInfo.plist" \
        "AutoSubmit" "-bool" "" "false"
}

apply_ecosystemanalyticsd() {
    _lctl "ecosystemanalyticsd" "system" "com.apple.ecosystemanalyticsd"
}

apply_geoanalyticsd() {
    _lctl "geoanalyticsd" "gui" "com.apple.geoanalyticsd"
}

# ── SIRI ────────────────────────────────────────────────────────────────────

apply_assistantd() {
    _lctl "assistantd" "gui" "com.apple.assistantd"
}

apply_siriknowledged() {
    _lctl "siriknowledged" "system" "com.apple.siriknowledged"
}

apply_siriinferenced() {
    _lctl "siriinferenced" "gui" "com.apple.siriinferenced"
}

apply_sirittsd() {
    _lctl "sirittsd" "gui" "com.apple.sirittsd"
}

apply_SiriAnalytics() {
    _lctl "SiriAnalytics" "gui" "com.apple.siri.context.service"
}

apply_assistant_cdmd() {
    _lctl "assistant_cdmd" "gui" "com.apple.assistant_cdmd"
}

apply_naturallanguaged() {
    # Label absent on some macOS 26 builds; _lctl handles gracefully
    _lctl "naturallanguaged" "system" "com.apple.naturallanguaged"
}

apply_corespeechd() {
    _lctl "corespeechd" "gui" "com.apple.corespeechd"
}

apply_SiriSuggestionsBookkeeping() {
    _lctl "SiriSuggestionsBookkeeping" "gui" \
        "com.apple.SiriSuggestionsSupport.SiriSuggestionsBookkeepingService"
}

apply_suggestd() {
    _lctl "suggestd" "gui" "com.apple.suggestd"
}

apply_routined() {
    _lctl "routined" "system" "com.apple.routined"
}

apply_duetexpertd() {
    _lctl "duetexpertd" "system" "com.apple.duetexpertd"
}

apply_ospredictiond() {
    _lctl "ospredictiond" "system" "com.apple.ospredictiond"
}

apply_siriactionsd() {
    _lctl "siriactionsd" "gui" "com.apple.siriactionsd"
}

apply_followupd() {
    _lctl "followupd" "gui" "com.apple.followupd"
}

apply_liveactivitiesd() {
    _lctl "liveactivitiesd" "gui" "com.apple.liveactivitiesd"
}

apply_statusKitAgent() {
    _lctl "statusKitAgent" "gui" "com.apple.StatusKitAgent"
}

apply_AppSSOAgent() {
    _lctl "AppSSOAgent" "gui" "com.apple.AppSSOAgent"
}

apply_AppSSODaemon() {
    _lctl "AppSSODaemon" "system" "com.apple.AppSSO.AppSSODaemon"
}

apply_siri_disabled() {
    _dfw_disable "siri_disabled" \
        "com.apple.assistant.support" "SiriEnabled" "-bool" "true" "false"
}

apply_siri_voice_feedback() {
    _dfw_disable "siri_voice_feedback" \
        "com.apple.Siri" "VoiceTriggerUserEnabled" "-bool" "" "false"
}

# ── ICLOUD ──────────────────────────────────────────────────────────────────

apply_bird() {
    _lctl "bird" "gui" "com.apple.bird"
}

apply_cloudd_user() {
    _lctl "cloudd_user" "gui" "com.apple.cloudd"
}

apply_cloudphotod() {
    _lctl "cloudphotod" "gui" "com.apple.cloudphotod"
}

apply_cloudsettingssyncagent() {
    _lctl "cloudsettingssyncagent" "gui" "com.apple.cloudsettingssyncagent"
}

apply_iCloudNotificationAgent() {
    _lctl "iCloudNotificationAgent" "gui" "com.apple.iCloudNotificationAgent"
}

apply_syncdefaultsd() {
    _lctl "syncdefaultsd" "gui" "com.apple.syncdefaultsd"
}

apply_cmfsyncagent() {
    _lctl "cmfsyncagent" "gui" "com.apple.cmfsyncagent"
}

apply_accountsd() {
    _lctl "accountsd" "gui" "com.apple.accountsd"
}

apply_appleaccountd() {
    _lctl "appleaccountd" "gui" "com.apple.appleaccountd"
}

apply_protectedcloudkeysyncing() {
    _lctl "protectedcloudkeysyncing" "gui" \
        "com.apple.protectedcloudstorage.protectedcloudkeysyncing"
}

apply_icloud_drive_defaults() {
    _dfw_disable "icloud_drive_defaults" \
        "NSGlobalDomain" "NSDocumentSaveNewDocumentsToCloud" "-bool" "true" "false"
}

# ── MEDIA ───────────────────────────────────────────────────────────────────

apply_itunescloudd() {
    _lctl "itunescloudd" "gui" "com.apple.itunescloudd"
}

apply_AMPDeviceDiscoveryAgent() {
    _lctl "AMPDeviceDiscoveryAgent" "gui" "com.apple.AMPDeviceDiscoveryAgent"
}

apply_AirPlayUIAgent() {
    _lctl "AirPlayUIAgent" "gui" "com.apple.AirPlayUIAgent"
}

apply_sharingd() {
    _lctl "sharingd" "gui" "com.apple.sharingd"
}

apply_airdrop_defaults() {
    _dfw_disable "airdrop_defaults" \
        "com.apple.NetworkBrowser" "DisableAirDrop" "-bool" "false" "true"
}

apply_handoff_defaults() {
    local current_adv current_rcv
    current_adv=$(dfw read com.apple.coreduetd ActivityAdvertisingAllowed 2>/dev/null || echo "(not set)")
    current_rcv=$(dfw  read com.apple.coreduetd ActivityReceivingAllowed  2>/dev/null || echo "(not set)")
    local current="adv=${current_adv} rcv=${current_rcv}"

    [ "$DRY_RUN" = true ] && { _dry_item "$_ITEM_NUM" "handoff_defaults" "defaults" "$current" "both true" "both false"; return; }
    _confirm_item "$_ITEM_NUM" "handoff_defaults" "defaults" "${_ITEM_DESC}" "$current" "both true (macOS default)" "both false"

    case "$ACTION" in
        disable)
            dfw write com.apple.coreduetd ActivityAdvertisingAllowed -bool false
            dfw write com.apple.coreduetd ActivityReceivingAllowed   -bool false
            ok "handoff_defaults — Handoff advertising and receiving disabled"
            ;;
        restore)
            dfw write com.apple.coreduetd ActivityAdvertisingAllowed -bool true
            dfw write com.apple.coreduetd ActivityReceivingAllowed   -bool true
            ok "handoff_defaults — Handoff restored to macOS defaults (both enabled)"
            ;;
        skip) log "handoff_defaults — skipped" ;;
    esac
}

apply_ContinuityCaptureAgent() {
    _lctl "ContinuityCaptureAgent" "gui" "com.apple.cmio.ContinuityCaptureAgent"
}

apply_mediaremoteagent() {
    _lctl "mediaremoteagent" "gui" "com.apple.mediaremoteagent"
}

apply_replayd() {
    _lctl "replayd" "gui" "com.apple.replayd"
}

apply_BTServer_cloudpairing() {
    _lctl "BTServer_cloudpairing" "gui" "com.apple.BTServer.cloudpairing"
}

# ── APPLE INTELLIGENCE ──────────────────────────────────────────────────────

apply_generativeexperiencesd() {
    _lctl "generativeexperiencesd" "system" "com.apple.generativeexperiencesd"
}

apply_intelligencecontextd() {
    _lctl "intelligencecontextd" "system" "com.apple.intelligencecontextd"
}

apply_IntelligencePlatformComputeService() {
    # macOS 26: intelligenceplatformd is the main label; intelligencetasksd is the task engine
    _lctl "IntelligencePlatformComputeService" "gui" "com.apple.intelligenceplatformd"
    launchctl bootout  "gui/$REAL_UID/com.apple.intelligencetasksd" 2>/dev/null || true
    _db_queue_disable "gui" "com.apple.intelligencetasksd"
}

apply_privatecloudcomputed() {
    _lctl "privatecloudcomputed" "system" "com.apple.privatecloudcomputed"
}

apply_ModelCatalogAgent() {
    _lctl "ModelCatalogAgent" "gui" "com.apple.ModelCatalogAgent"
}

apply_modelcatalogd() {
    _lctl "modelcatalogd" "system" "com.apple.modelcatalogd"
}

apply_AppleIntelligenceReporting() {
    # Label not present in all macOS 26 builds; handled gracefully
    _lctl "AppleIntelligenceReporting" "gui" \
        "com.apple.AppleIntelligenceReporting.AppleIntelligenceReportingProcessingService"
}

# ── APP STORE ───────────────────────────────────────────────────────────────

apply_promotedcontentd() {
    _lctl "promotedcontentd" "gui" "com.apple.ap.promotedcontentd"
}

apply_adprivacyd() {
    _lctl "adprivacyd" "gui" "com.apple.ap.adprivacyd"
}

apply_amsengagementd() {
    _lctl "amsengagementd" "gui" "com.apple.amsengagementd"
}

apply_amsondevicestoraged() {
    _lctl "amsondevicestoraged" "gui" "com.apple.amsondevicestoraged"
}

apply_amsaccountsd() {
    _lctl "amsaccountsd" "gui" "com.apple.amsaccountsd"
}

apply_appstoreagent() {
    _lctl "appstoreagent" "gui" "com.apple.appstoreagent"
}

apply_commerce() {
    _lctl "commerce" "gui" "com.apple.commerce"
}

apply_triald() {
    _lctl "triald" "gui" "com.apple.triald"
}

apply_triald_system() {
    _lctl "triald_system" "system" "com.apple.triald"
}

apply_TrialArchivingService() {
    _lctl "TrialArchivingService" "gui" \
        "com.apple.TrialServer.TrialArchivingService"
}

apply_SetStoreUpdateService() {
    _lctl "SetStoreUpdateService" "gui" \
        "com.apple.CascadeSets.SetStoreUpdateService"
}

# ── MAIL / MESSAGING ────────────────────────────────────────────────────────

apply_maild() {
    _lctl "maild" "gui" "com.apple.email.maild"
}

apply_calaccessd() {
    # calaccessd not a standalone label in macOS 26; graceful no-op if absent
    _lctl "calaccessd" "gui" "com.apple.calaccessd"
}

apply_contactsd() {
    _lctl "contactsd" "gui" "com.apple.contactsd"
}

apply_remindd() {
    _lctl "remindd" "gui" "com.apple.remindd"
}

apply_dataaccessd() {
    _lctl "dataaccessd" "gui" "com.apple.dataaccess.dataaccessd"
}

apply_imagent() {
    _lctl "imagent" "gui" "com.apple.imagent"
}

apply_callservicesd() {
    _lctl "callservicesd" "gui" "com.apple.telephonyutilities.callservicesd"
}

apply_communicationtrustd() {
    _lctl "communicationtrustd" "system" "com.apple.communicationtrustd"
}

apply_contactsdonationagent() {
    _lctl "contactsdonationagent" "gui" "com.apple.contacts.donation-agent"
}

# ── SOCIAL ──────────────────────────────────────────────────────────────────

apply_mapssyncd() {
    _lctl "mapssyncd" "gui" "com.apple.Maps.mapssyncd"
}

apply_weatherd() {
    _lctl "weatherd" "system" "com.apple.weatherd"
}

apply_financed() {
    _lctl "financed" "system" "com.apple.financed"
}

apply_StocksKitService() {
    _lctl "StocksKitService" "gui" \
        "com.apple.StocksKit.StocksKitService"
}

apply_homeeventsd() {
    # Label may differ across macOS versions; try known variants
    _lctl "homeeventsd" "system" "com.apple.homekit.homeeventsd" 2>/dev/null || \
    _lctl "homeeventsd" "system" "com.apple.HomeKitEvents.homeeventsd"
}

apply_homed() {
    _lctl "homed" "system" "com.apple.homed"
}

apply_homeenergyd() {
    _lctl "homeenergyd" "system" "com.apple.homeenergyd"
}

apply_FindMyMacd() {
    _lctl "FindMyMacd" "system" "com.apple.findmymacd"
}

apply_findmybeaconingd() {
    _lctl "findmybeaconingd" "system" "com.apple.findmy.findmybeaconingd"
}

apply_findmylocateagent() {
    _lctl "findmylocateagent" "gui" "com.apple.findmy.findmylocateagent"
}

apply_searchpartyd() {
    _lctl "searchpartyd" "system" "com.apple.icloud.searchpartyd"
}

apply_searchpartyuseragent() {
    _lctl "searchpartyuseragent" "gui" "com.apple.icloud.searchpartyuseragent"
}

apply_sociallayerd() {
    _lctl "sociallayerd" "gui" "com.apple.sociallayerd"
}

apply_ndoagent() {
    _lctl "ndoagent" "gui" "com.apple.ndoagent"
}

apply_photolibraryd() {
    _lctl "photolibraryd" "gui" "com.apple.photolibraryd"
}

apply_photoanalysisd() {
    _lctl "photoanalysisd" "gui" "com.apple.photoanalysisd"
}

apply_mediaanalysisd() {
    _lctl "mediaanalysisd" "system" "com.apple.mediaanalysisd"
}

# ── GAMING ──────────────────────────────────────────────────────────────────

apply_gamecontrolleragentd() {
    _lctl "gamecontrolleragentd" "gui" "com.apple.GameController.gamecontrolleragentd"
}

apply_gamecontrollerd() {
    _lctl "gamecontrollerd" "system" "com.apple.GameController.gamecontrollerd"
}

apply_gamepolicyd() {
    _lctl "gamepolicyd" "system" "com.apple.gamepolicyd"
}

apply_GameController_agent() {
    # Alias — same label as gamecontrolleragentd; skip if already handled
    launchctl bootout  "gui/$REAL_UID/com.apple.GameController.gamecontrolleragentd" 2>/dev/null || true
    _db_queue_disable "gui" "com.apple.GameController.gamecontrolleragentd"
    ok "GameController_agent — gui label ensured disabled"
}

apply_GamePolicyAgent() {
    _lctl "GamePolicyAgent" "gui" "com.apple.GamePolicyAgent"
}

# ── MDM ─────────────────────────────────────────────────────────────────────

apply_remotemanagementd() {
    _lctl "remotemanagementd" "system" "com.apple.remotemanagementd"
}

apply_RemoteManagementAgent() {
    _lctl "RemoteManagementAgent" "gui" "com.apple.RemoteManagementAgent"
}

apply_ManagedSettingsAgent() {
    _lctl "ManagedSettingsAgent" "gui" "com.apple.ManagedSettingsAgent"
}

apply_managedappdistributiond() {
    _lctl "managedappdistributiond" "system" "com.apple.managedappdistributiond"
}

apply_managedappdistributionagent() {
    _lctl "managedappdistributionagent" "gui" "com.apple.managedappdistributionagent"
}

# ── UPDATES ─────────────────────────────────────────────────────────────────

apply_softwareupdated() {
    # macOS 26 uses com.apple.softwareupdated; also stop mobile variant
    _lctl "softwareupdated" "system" "com.apple.softwareupdated"
    launchctl bootout  "system/com.apple.mobile.softwareupdated" 2>/dev/null || true
    launchctl disable  "system/com.apple.mobile.softwareupdated" 2>/dev/null || true
}

apply_SoftwareUpdateNotificationManager() {
    _lctl "SoftwareUpdateNotificationManager" "gui" \
        "com.apple.SoftwareUpdateNotificationManager"
}

apply_autoupdate_defaults() {
    local current_check current_dl current_au
    current_check=$(dfw read com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null || echo "(not set)")
    current_dl=$(   dfw read com.apple.SoftwareUpdate AutomaticDownload     2>/dev/null || echo "(not set)")
    current_au=$(   dfw read com.apple.SoftwareUpdate AutoUpdate            2>/dev/null || echo "(not set)")
    local current="check=${current_check} download=${current_dl} autoupdate=${current_au}"

    [ "$DRY_RUN" = true ] && { _dry_item "$_ITEM_NUM" "autoupdate_defaults" "defaults" "$current" "all true" "all false"; return; }
    _confirm_item "$_ITEM_NUM" "autoupdate_defaults" "defaults" "${_ITEM_DESC}" \
        "$current" "all true (macOS default)" "all false"

    case "$ACTION" in
        disable)
            dfw write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
            dfw write com.apple.SoftwareUpdate AutomaticDownload     -bool false
            dfw write com.apple.SoftwareUpdate AutoUpdate            -bool false
            sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate \
                AutomaticCheckEnabled -bool false 2>/dev/null || true
            sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate \
                AutomaticDownload -bool false 2>/dev/null || true
            ok "autoupdate_defaults — all auto-update flags set to false"
            ;;
        restore)
            dfw write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true
            dfw write com.apple.SoftwareUpdate AutomaticDownload     -bool true
            dfw write com.apple.SoftwareUpdate AutoUpdate            -bool true
            sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate \
                AutomaticCheckEnabled -bool true 2>/dev/null || true
            sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate \
                AutomaticDownload -bool true 2>/dev/null || true
            ok "autoupdate_defaults — auto-update flags restored to macOS defaults"
            ;;
        skip) log "autoupdate_defaults — skipped" ;;
    esac
}

apply_assetsubscriptiond() {
    _lctl "assetsubscriptiond" "gui" "com.apple.assetsubscriptiond"
}

apply_jetpackassetd() {
    _lctl "jetpackassetd" "system" "com.apple.jetpackassetd"
}

apply_mobileassetd() {
    _lctl "mobileassetd" "system" "com.apple.mobileassetd"
}

# ---------------------------------------------------------------------------
# DISPATCH
# ---------------------------------------------------------------------------
dispatch_apply() {
    _ITEM_NUM="$1"
    local key="$2"
    _ITEM_GROUP="$3"
    _ITEM_DESC="$4"
    local fn="apply_${key}"
    if declare -f "$fn" > /dev/null 2>&1; then
        "$fn"
    else
        warn "No apply function found for key: $key"
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
if [ ${#WORK_LIST[@]} -eq 0 ]; then
    warn "No items match the given filters. Use --list to see all keys."
    exit 0
fi

APPLIED=0
SKIPPED=0
NUM=0
_ITEM_NUM=0
_ITEM_DESC=""
_ITEM_GROUP=""

for entry in "${WORK_LIST[@]}"; do
    NUM=$((NUM + 1))
    local_idx=$(echo "$entry"    | cut -d'|' -f1)
    local_key=$(echo "$entry"    | cut -d'|' -f2)
    local_group=$(echo "$entry"  | cut -d'|' -f3)
    local_method=$(echo "$entry" | cut -d'|' -f4)
    local_desc=$(echo "$entry"   | cut -d'|' -f5)

    if [ "$DRY_RUN" = false ] && [ "$NUM" = 1 ]; then
        header "Processing ${#WORK_LIST[@]} item(s) — mode: $([ "$RESTORE_MODE" = true ] && echo RESTORE || echo DISABLE)"
    fi

    dispatch_apply "$NUM" "$local_key" "$local_group" "$local_desc"

    if [ "$DRY_RUN" = false ]; then
        case "$ACTION" in
            disable|restore) APPLIED=$((APPLIED + 1)) ;;
            *)               SKIPPED=$((SKIPPED + 1)) ;;
        esac
    fi
done

# ---------------------------------------------------------------------------
# Flush disable database — single write for all queued label changes
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = false ] && [ "$APPLIED" -gt 0 ]; then
    echo ""
    _db_flush
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
        echo "  launchctl changes take effect immediately."
        echo "  defaults changes take effect on next login or app restart."
        echo "  To restore everything: sudo ./disable.sh --yes --restore"
    fi
fi
log "Log: $LOG"
echo ""
