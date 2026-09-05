#!/usr/bin/env bash
#
# demon-mac.sh — MAC address randomizer daemon entrypoint.
#
# Modes:
#   boot       — invoked at boot via demon-mac-boot.service
#   connection — invoked on NetworkManager pre-up via dispatcher
#                (argv2 = iface, argv3 = NM CONNECTION_ID / SSID)
#   rotate     — invoked periodically via demon-mac-rotate.timer
#
# All behavior controlled via /etc/demon-mac.conf.
#
# Environment:
#   DEMON_MAC_CONF          — override config path (default: /etc/demon-mac.conf)
#   DEMON_MAC_DRY_RUN=1     — log new MAC and state changes; skip actual ip link set
#   DEMON_MAC_BYPASS_PHYSICAL=1 — skip is_physical() filter (test-only)
#
# Exit codes:
#   0  — success or skipped (always, except usage errors)
#   64 — usage error (unknown mode, missing iface in connection mode)
#
set -euo pipefail

CONF_FILE="${DEMON_MAC_CONF:-/etc/demon-mac.conf}"
DRY_RUN="${DEMON_MAC_DRY_RUN:-0}"

# ----- Logging -----
log() {
    local level="${LOG_LEVEL:-info}"
    local prio
    case "$level" in
        debug) prio=debug ;;
        info)  prio=info ;;
        warn)  prio=warning ;;
        error) prio=err ;;
    esac
    local msg="mode=${MODE:-?} iface=${IFACE:-?} ssid=${SSID:-?} $*"
    logger -t demon-mac -p "user.${prio}" -- "$msg" 2>/dev/null || true
    printf '%s\n' "$msg" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s %s\n' "$(date -u +%FT%TZ)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ----- Argument parsing -----
MODE="${1:-boot}"
IFACE="${2:-}"
SSID="${3:-}"

if [[ "$MODE" != "boot" && "$MODE" != "connection" && "$MODE" != "rotate" ]]; then
    echo "demon-mac: unknown mode '$MODE' (expected: boot | connection | rotate)" >&2
    exit 64
fi

if [[ "$MODE" == "connection" && -z "$IFACE" ]]; then
    echo "demon-mac: connection mode requires iface argument" >&2
    exit 64
fi

# ----- Load config -----
if [[ ! -r "$CONF_FILE" ]]; then
    echo "demon-mac: config $CONF_FILE not readable; running disabled" >&2
    ENABLED=false
else
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

# ----- Master kill-switch -----
ENABLED="${ENABLED:-false}"
if [[ "$ENABLED" != "true" ]]; then
    log "ENABLED!=true; exiting"
    exit 0
fi

# ----- Defaults -----
ROTATION_POLICY="${ROTATION_POLICY:-connection}"
PIN_MODE="${PIN_MODE:-none}"          # none | ssid | iface
TARGETS="${TARGETS:-}"
STATE_FILE="${STATE_FILE:-/var/lib/demon-mac/state}"
TOUCHED_PROFILES="${TOUCHED_PROFILES:-/var/lib/demon-mac/touched-profiles}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"
STABILIZE_IPV6="${STABILIZE_IPV6:-true}"
MAC_PREFIX="${MAC_PREFIX:-}"
NM_CLONED_MAC_POLICY="${NM_CLONED_MAC_POLICY:-preserve}"  # preserve|none
MANAGEMENT_MODE="${MANAGEMENT_MODE:-supervisor}"          # supervisor|daemon|hybrid
NM_CLONED_MAC="${NM_CLONED_MAC:-stable}"                  # stable|random (target value in supervisor mode)

# ----- MAC_PREFIX validation -----
# Format: XX:XX (two hex octets separated by colon).
# First byte must be locally-administered + unicast:
#   bit 0 (multicast) = 0
#   bit 1 (U/L)       = 1
# so first_byte & 0x03 == 0x02.
# Valid first bytes include: 02, 06, 0A, 0E, 12, ..., 7E, 82, ..., FE.
if [[ -n "$MAC_PREFIX" ]]; then
    if [[ ! "$MAC_PREFIX" =~ ^([0-9a-fA-F]{2}):([0-9a-fA-F]{2})$ ]]; then
        log "WARN: MAC_PREFIX='$MAC_PREFIX' invalid format (expected XX:XX); falling back to full random"
        MAC_PREFIX=""
    else
        first_byte=$(( 16#${BASH_REMATCH[1]} ))
        if (( (first_byte & 0x03) != 0x02 )); then
            log "WARN: MAC_PREFIX='$MAC_PREFIX' first byte 0x$(printf '%02x' "$first_byte") is not locally-administered unicast; falling back to full random"
            MAC_PREFIX=""
        fi
    fi
fi

if [[ "$PIN_MODE" != "none" && "$PIN_MODE" != "ssid" && "$PIN_MODE" != "iface" ]]; then
    log "WARN: PIN_MODE='$PIN_MODE' invalid (expected none|ssid|iface); treating as none"
    PIN_MODE="none"
fi

if [[ "$NM_CLONED_MAC_POLICY" != "preserve" && "$NM_CLONED_MAC_POLICY" != "none" ]]; then
    log "WARN: NM_CLONED_MAC_POLICY='$NM_CLONED_MAC_POLICY' invalid (expected preserve|none); treating as none"
    NM_CLONED_MAC_POLICY="none"
fi

if [[ "$MANAGEMENT_MODE" != "supervisor" && "$MANAGEMENT_MODE" != "daemon" && "$MANAGEMENT_MODE" != "hybrid" ]]; then
    log "WARN: MANAGEMENT_MODE='$MANAGEMENT_MODE' invalid (expected supervisor|daemon|hybrid); treating as supervisor"
    MANAGEMENT_MODE="supervisor"
fi

if [[ "$NM_CLONED_MAC" != "stable" && "$NM_CLONED_MAC" != "random" ]]; then
    log "WARN: NM_CLONED_MAC='$NM_CLONED_MAC' invalid (expected stable|random); treating as stable"
    NM_CLONED_MAC="stable"
fi

# Cross-key sanity: warn loudly when supervisor can't do what the operator asked for.
if [[ "$MANAGEMENT_MODE" == "supervisor" ]]; then
    [[ -n "$MAC_PREFIX" ]] && log "WARN: MAC_PREFIX='$MAC_PREFIX' is ignored in supervisor mode (no kernel writes); switch MANAGEMENT_MODE=daemon"
    case "$ROTATION_POLICY" in
        daily|weekly|monthly|once|boot)
            log "WARN: ROTATION_POLICY=$ROTATION_POLICY is ignored in supervisor mode (no kernel writes); switch MANAGEMENT_MODE=daemon or daemon-mode-hybrid"
            ;;
    esac
fi

log "config: mode=$MANAGEMENT_MODE policy=$ROTATION_POLICY pin=$PIN_MODE targets='$TARGETS' prefix='$MAC_PREFIX' state=$STATE_FILE nm_policy=$NM_CLONED_MAC_POLICY nm_target=$NM_CLONED_MAC"

# ----- Lock -----
# Single-flight: serialize concurrent invocations (boot + rotate.timer
# can race within seconds; both call this script). Lock lives next to
# the state file (same local FS, same dir).
#
# Only needed in daemon/hybrid mode (where we mutate kernel state and
# write the state file). Supervisor mode is read-only with respect to
# kernel — nmcli handles its own concurrency.
if [[ "$MANAGEMENT_MODE" != "supervisor" ]]; then
    LOCK_FILE="$(dirname "$STATE_FILE")/demon-mac.lock"
    acquire_lock() {
        local dir
        dir="$(dirname "$LOCK_FILE")"
        [[ -d "$dir" ]] || mkdir -p -m 700 "$dir"
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            log "another instance holds $LOCK_FILE; exiting"
            exit 0
        fi
    }
    acquire_lock
fi

# ----- Helpers: filtering -----
IFS=',' read -ra TARGET_ARR <<< "$TARGETS"

in_targets() {
    [[ -z "$TARGETS" ]] && return 0
    local t
    for t in "${TARGET_ARR[@]}"; do
        [[ "$1" == "$t" ]] && return 0
    done
    return 1
}

# Test if an interface is "real enough" to need MAC randomization.
# Filters:
#   - lo (loopback; never randomize)
#   - interfaces without /sys/class/net/<iface>/device (bonds `bond0`,
#     teams `team0`, bridges `br0`/`br-xyz`, docker `docker0`,
#     libvirt `virbr0`/`vnet*`, veth pairs `veth*`, tun/tap) — these
#     have no physical NIC behind them; rotating their MAC is either
#     pointless or actively disruptive (changing bond-master MAC
#     confuses aggregation; changing bridge MAC changes bridge ID
#     and reshuffles the spanning tree).
#   - interfaces that don't exist (defensive)
#
# Bond/team slaves (eth0, eth1) DO have /sys/class/net/<iface>/device
# and ARE processed — they're real hardware.
#
# If you have a weird stack where a bond master has a /device symlink,
# set TARGETS explicitly to the slave names.
is_physical() {
    local iface="$1"
    [[ "${DEMON_MAC_BYPASS_PHYSICAL:-0}" == "1" ]] && return 0
    [[ "$iface" == "lo" ]] && return 1
    [[ -e "/sys/class/net/$iface/device" ]] || return 1
    ip link show dev "$iface" &>/dev/null || return 1
    return 0
}

# ----- Pin key resolution -----
# Returns the SSID key for state lookup. Empty = iface-only pin.
lookup_key() {
    local trigger="$1" ssid="$2"
    if [[ "$trigger" == "connection" && "$PIN_MODE" == "ssid" && -n "$ssid" ]]; then
        printf '%s' "$ssid"
    else
        printf ''
    fi
}

# ----- MAC generation -----
generate_mac() {
    local hex
    if [[ -n "$MAC_PREFIX" ]]; then
        # Use configured prefix; remaining 4 octets random.
        hex="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        printf '%s:%s:%s:%s:%s:%s\n' \
            "${MAC_PREFIX:0:2}" "${MAC_PREFIX:3:2}" \
            "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}"
    else
        # Full random; first byte forced to 0x02 (locally-administered + unicast + individual).
        hex="$(head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        printf '02:%s:%s:%s:%s:%s\n' \
            "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}"
    fi
}

# ----- State management -----
# State file formats (read both, write always new):
#   legacy:  iface|mac|ts            (3 columns)
#   new:     iface|ssid|mac|ts       (4 columns, ssid may be empty for boot-pin)
#
# All field comparisons are awk-based (no shell glob / grep regex), so
# SSID values containing '|' or regex metacharacters are matched exactly.
#
# read_state_mac_for(iface, key): key is SSID or empty.
# Tries (iface, key) first; falls back to (iface, "") new entry;
# falls back to legacy iface-only entry.
read_state_mac_for() {
    local iface="$1" key="$2"
    [[ -r "$STATE_FILE" ]] || return 1
    local entry

    entry="$(awk -F'|' -v iface="$iface" -v key="$key" \
        'NF==4 && $1==iface && $2==key {print $3; exit}' \
        "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$entry" ]]; then
        printf '%s' "$entry"
        return 0
    fi

    entry="$(awk -F'|' -v iface="$iface" \
        'NF==3 && $1==iface {print $2; exit}' \
        "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$entry" ]]; then
        printf '%s' "$entry"
        return 0
    fi

    return 1
}

read_state_ts_for() {
    local iface="$1" key="$2"
    [[ -r "$STATE_FILE" ]] || return 1
    local entry

    entry="$(awk -F'|' -v iface="$iface" -v key="$key" \
        'NF==4 && $1==iface && $2==key {print $4; exit}' \
        "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$entry" ]]; then
        printf '%s' "$entry"
        return 0
    fi

    entry="$(awk -F'|' -v iface="$iface" \
        'NF==3 && $1==iface {print $3; exit}' \
        "$STATE_FILE" 2>/dev/null)"
    if [[ -n "$entry" ]]; then
        printf '%s' "$entry"
        return 0
    fi

    return 1
}

write_state() {
    local iface="$1" key="$2" mac="$3" ts="$4"
    local dir tmp
    dir="$(dirname "$STATE_FILE")"
    [[ -d "$dir" ]] || mkdir -p -m 700 "$dir"
    tmp="$(mktemp -p "$dir" .state.XXXXXX)"

    if [[ -r "$STATE_FILE" ]]; then
        # Drop matching entries (kept in awk — field-safe, no regex):
        #   - SSID-pinned write: drop (iface, key) new-format entries only
        #   - boot-pin write:    drop all entries for this iface (both formats)
        if [[ -z "$key" ]]; then
            awk -F'|' -v iface="$iface" \
                '!(($1==iface) && (NF==4 || NF==3)) {print}' \
                "$STATE_FILE" >> "$tmp" || true
        else
            awk -F'|' -v iface="$iface" -v key="$key" \
                '!(NF==4 && $1==iface && $2==key) {print}' \
                "$STATE_FILE" >> "$tmp" || true
        fi
    fi

    printf '%s|%s|%s|%s\n' "$iface" "$key" "$mac" "$ts" >> "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

now_iso() {
    date -u +%FT%TZ
}

age_seconds() {
    local ts="$1"
    local ts_epoch
    ts_epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
    [[ "$ts_epoch" -eq 0 ]] && { echo 99999999; return; }
    echo $(( $(date +%s) - ts_epoch ))
}

# ----- Decision: should this iface/SSID be rotated now? -----
# Args: iface ssid trigger
should_rotate() {
    local iface="$1" ssid="$2" trigger="$3"
    local key
    key="$(lookup_key "$trigger" "$ssid")"

    case "$ROTATION_POLICY" in
        connection)
            [[ "$trigger" == "connection" ]] && return 0
            return 1
            ;;
        boot)
            [[ "$trigger" == "boot" ]] && return 0
            return 1
            ;;
        once)
            local last
            last="$(read_state_mac_for "$iface" "$key" || true)"
            [[ -z "$last" ]] && return 0
            return 1
            ;;
        daily)
            local last_ts age
            last_ts="$(read_state_ts_for "$iface" "$key" || true)"
            [[ -z "$last_ts" ]] && return 0
            age="$(age_seconds "$last_ts")"
            (( age > 86400 )) && return 0
            return 1
            ;;
        weekly)
            local last_ts age
            last_ts="$(read_state_ts_for "$iface" "$key" || true)"
            [[ -z "$last_ts" ]] && return 0
            age="$(age_seconds "$last_ts")"
            (( age > 604800 )) && return 0
            return 1
            ;;
        monthly)
            local last_ts age
            last_ts="$(read_state_ts_for "$iface" "$key" || true)"
            [[ -z "$last_ts" ]] && return 0
            age="$(age_seconds "$last_ts")"
            (( age > 2592000 )) && return 0
            return 1
            ;;
        *)
            log "WARN: unknown ROTATION_POLICY=$ROTATION_POLICY; failing safe (rotate)"
            return 0
            ;;
    esac
}

# ----- Self-heal: re-apply state-recorded MAC if kernel has drifted -----
# Used by boot / rotate triggers. The daemon's contract for non-connection
# policies (daily / weekly / monthly / once / boot) is: "this iface must
# have the MAC recorded in state, and only rotate when the policy says so."
# If something (NM profile, driver reset, manual edit) reverted the
# kernel MAC between daemon runs, force-set it back from state, then
# enforce the NM profile so the next reactivation doesn't revert again.
#
# Not used by connection mode — that policy always rotates fresh on
# every dispatcher event, so applying the stale state MAC first is
# pointless (apply_change overwrites it a moment later).
#
# Idempotent and cheap: one state read + one ip link show per iface.
# Bails early if state is empty (no record yet) or kernel matches.
reconcile_iface() {
    local iface="$1" key="$2"
    local expected_mac current_mac

    expected_mac="$(read_state_mac_for "$iface" "$key" 2>/dev/null || true)"
    [[ -z "$expected_mac" ]] && return 0

    if [[ -n "${DEMON_MAC_FAKE_CURRENT_MAC:-}" ]]; then
        current_mac="$DEMON_MAC_FAKE_CURRENT_MAC"
    else
        current_mac="$(ip -o link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {for(i=1;i<=NF;i++) if($i=="link/ether") {print $(i+1); exit}}')"
    fi
    [[ -z "$current_mac" ]] && return 0

    if [[ "$current_mac" == "$expected_mac" ]]; then
        return 0
    fi

    log "INFO: iface=$iface MAC drifted from state (kernel=$current_mac state=$expected_mac); re-applying state value"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: would re-apply MAC $expected_mac on $iface"
        enforce_nm_cloned_mac
        return 0
    fi

    local err
    err="$(mktemp)"
    if ! ip link set dev "$iface" down 2>"$err"; then
        log "WARN: reconcile down failed for $iface: $(<"$err")"
        rm -f "$err"
        return 0
    fi
    if ip link set dev "$iface" address "$expected_mac" 2>"$err"; then
        ip link set dev "$iface" up 2>/dev/null || true
        log "INFO: iface=$iface MAC re-applied from state: $current_mac -> $expected_mac"
    else
        log "WARN: reconcile address failed for $iface: $(<"$err")"
        ip link set dev "$iface" up 2>/dev/null || true
    fi
    rm -f "$err"
    enforce_nm_cloned_mac
    return 0
}

# ----- Track profiles touched by the daemon (for uninstall restore) -----
# Records the original NM profile values BEFORE the daemon modifies
# them. uninstall.sh reads this file and restores the originals.
# Format: UUID|conn_type|original_cloned|original_random
#   - conn_type: 802-11-wireless | 802-3-ethernet
#   - original_cloned: "" (was unset) or the previous MAC literal /
#     "preserve" / "stable" / "random" / "permanent"
#   - original_random: "" (was unset / "default") for ethernet always ""
# Idempotent: if a UUID is already tracked, the new record is ignored
# so we don't lose the original (e.g. if daemon later also touches
# random-field on the same profile, we keep the original for both).
record_touched_profile() {
    local uuid="$1" conn_type="$2" orig_cloned="$3" orig_random="$4"
    [[ -z "$uuid" ]] && return 0
    local file="${DEMON_MAC_TOUCHED_PROFILES:-$TOUCHED_PROFILES}"
    local dir
    dir="$(dirname "$file")"
    [[ -d "$dir" ]] || mkdir -p -m 700 "$dir" 2>/dev/null || return 0

    if [[ -r "$file" ]] && \
        awk -F'|' -v u="$uuid" '$1==u {found=1} END {exit !found}' "$file"; then
        return 0
    fi

    printf '%s|%s|%s|%s\n' "$uuid" "$conn_type" "$orig_cloned" "$orig_random" \
        >> "$file" 2>/dev/null || return 0
    chmod 600 "$file" 2>/dev/null || true
    return 0
}

# ----- NM cloned-mac-address enforcement (daemon / hybrid mode) -----
# NM ≥ 1.4 has 802-11-wireless.cloned-mac-address /
# 802-3-ethernet.cloned-mac-address. If the profile is set to
# `random` or `stable`, NM overwrites our MAC on the next profile
# activation. `preserve` tells NM to use whatever MAC is currently
# on the device — i.e. the one we just set. We enforce this
# idempotently (no-op if already preserve), and record the original
# value so uninstall.sh can restore it.
enforce_nm_cloned_mac() {
    [[ "$MODE" == "connection" ]] || return 0
    [[ "$NM_CLONED_MAC_POLICY" == "preserve" ]] || return 0
    [[ -n "${CONNECTION_UUID:-}" ]] || return 0
    command -v nmcli >/dev/null 2>&1 || return 0

    local conn_type cloned_field
    conn_type="$(nmcli -t -g connection.type con show uuid "$CONNECTION_UUID" 2>/dev/null | head -1)"
    case "$conn_type" in
        802-11-wireless) cloned_field="802-11-wireless.cloned-mac-address" ;;
        802-3-ethernet)  cloned_field="802-3-ethernet.cloned-mac-address" ;;
        *) return 0 ;;
    esac

    local current
    current="$(nmcli -t -g "$cloned_field" con show uuid "$CONNECTION_UUID" 2>/dev/null | head -1)"
    [[ -z "$current" || "$current" == "--" ]] && current="(default)"

    if [[ "$current" != "preserve" ]]; then
        # Record original before modifying (so uninstall.sh can restore).
        record_touched_profile "$CONNECTION_UUID" "$conn_type" "$current" ""
        if nmcli connection modify uuid "$CONNECTION_UUID" "$cloned_field" preserve 2>/dev/null; then
            log "INFO: set $cloned_field=preserve on $CONNECTION_UUID (was: $current)"
        else
            log "WARN: nmcli modify $cloned_field=preserve failed for $CONNECTION_UUID (current: $current)"
        fi
    fi
}

# ----- Supervisor: ensure NM profile has the right cloned-mac settings -----
# For each iface passed in, find its active NM connection and idempotently
# ensure:
#   - <type>.cloned-mac-address              = $NM_CLONED_MAC (stable|random)
#   - 802-11-wireless.mac-address-randomization = 2            (Wi-Fi only)
#
# NM exposes `cloned-mac-address` (the libnm property name) under a
# type-specific prefix when accessed via `nmcli connection show` /
# `nmcli connection modify`:
#   - 802-11-wireless connections  →  802-11-wireless.cloned-mac-address
#   - 802-3-ethernet connections   →  802-3-ethernet.cloned-mac-address
# There is no type-agnostic `connection.cloned-mac-address` field on
# NM 1.x (libnm has it but nmcli auto-prefixes). So we pick the right
# field based on `connection.type`.
#
# `mac-address-randomization` is Wi-Fi-only — it's the master switch
# that makes NM honor `cloned-mac-address=stable|random` on wireless.
# Ethernet has no equivalent; setting `cloned-mac-address=random` on
# an ethernet profile is enough.
#
# In hybrid mode the daemon's kernel-direct pass will later set
# cloned-mac-address=preserve on the profile; here we instead pin
# mac-address-randomization to 0 so NM doesn't override the daemon's MAC.
#
# Returns 0 always; logs drift corrections. No state file, no lock,
# no kernel writes.
apply_nm_supervisor() {
    local iface="$1"
    local uuid=""

    if [[ -n "${CONNECTION_UUID:-}" ]]; then
        uuid="$CONNECTION_UUID"
    elif command -v nmcli >/dev/null 2>&1; then
        uuid="$(nmcli -t device show "$iface" 2>/dev/null \
            | sed -n 's/^GENERAL\.CON-UUID://p' | head -1)"
    fi

    [[ -z "$uuid" ]] && {
        log "iface=$iface: no active NM connection; supervisor no-op"
        return 0
    }

    if ! command -v nmcli >/dev/null 2>&1; then
        log "WARN: nmcli not in PATH; supervisor cannot configure $uuid"
        return 0
    fi

    # Determine connection type to pick the right fields. Only Wi-Fi and
    # Ethernet are relevant for MAC randomization — vpn/gsm/bridge/etc.
    # are not supported by the supervisor.
    local conn_type
    conn_type="$(nmcli -t -g connection.type con show uuid "$uuid" 2>/dev/null | head -1)"

    local cloned_field random_field="" target_random=""
    case "$conn_type" in
        802-11-wireless)
            cloned_field="802-11-wireless.cloned-mac-address"
            random_field="802-11-wireless.mac-address-randomization"
            if [[ "$MANAGEMENT_MODE" == "hybrid" ]]; then
                target_random="0"
            else
                target_random="2"
            fi
            ;;
        802-3-ethernet)
            cloned_field="802-3-ethernet.cloned-mac-address"
            # No master switch on ethernet; cloned-mac-address alone suffices.
            ;;
        *)
            log "iface=$iface: connection type '$conn_type' is not Wi-Fi or Ethernet; supervisor no-op"
            return 0
            ;;
    esac

    # Resolve target cloned value.
    local target_cloned
    if [[ "$MANAGEMENT_MODE" == "hybrid" ]]; then
        target_cloned="preserve"
    else
        target_cloned="$NM_CLONED_MAC"
    fi

    # Read current values.
    local current_cloned current_random
    current_cloned="$(nmcli -t -g "$cloned_field" con show uuid "$uuid" 2>/dev/null | head -1)"
    [[ -z "$current_cloned" || "$current_cloned" == "--" ]] && current_cloned="(unset)"
    if [[ -n "$random_field" ]]; then
        current_random="$(nmcli -t -g "$random_field" con show uuid "$uuid" 2>/dev/null | head -1)"
        [[ -z "$current_random" || "$current_random" == "--" ]] && current_random="(unset)"
    else
        current_random="n/a"
    fi

    local drift=0 changes=""

    if [[ "$current_cloned" != "$target_cloned" ]]; then
        # Record original before modifying (so uninstall.sh can restore).
        record_touched_profile "$uuid" "$conn_type" "$current_cloned" "${current_random:-}"
        if nmcli connection modify uuid "$uuid" "$cloned_field" "$target_cloned" 2>/dev/null; then
            changes+=" cloned-mac=${current_cloned}->${target_cloned}"
            drift=1
        else
            log "WARN: nmcli modify $cloned_field=$target_cloned failed for $uuid"
        fi
    fi

    if [[ -n "$random_field" && "$current_random" != "$target_random" ]]; then
        # Already-recorded record covers both fields; only record if we
        # somehow didn't (e.g. cloned matched but random drifted).
        if [[ "$drift" -eq 0 ]]; then
            record_touched_profile "$uuid" "$conn_type" "${current_cloned:-}" "$current_random"
        fi
        if nmcli connection modify uuid "$uuid" "$random_field" "$target_random" 2>/dev/null; then
            changes+=" mac-randomization=${current_random}->${target_random}"
            drift=1
        else
            log "WARN: nmcli modify $random_field=$target_random failed for $uuid"
        fi
    fi

    if [[ "$drift" -eq 0 ]]; then
        log "iface=$iface: profile $uuid ($conn_type) already supervised (cloned=$current_cloned randomization=$current_random)"
    else
        log "iface=$iface: profile $uuid ($conn_type) supervised —$changes"
    fi
    return 0
}

# ----- Apply MAC change -----
apply_change() {
    local iface="$1" key="$2"
    local new_mac old_mac actual_mac
    new_mac="$(generate_mac)"
    old_mac="$(ip -o link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {for(i=1;i<=NF;i++) if($i=="link/ether") {print $(i+1); exit}}')"

    log "iface=$iface key='$key' old_mac=$old_mac new_mac=$new_mac"

    # Short-circuit: kernel already at target MAC (random collision, or
    # previous change was reverted by driver). Don't flap the link.
    if [[ -n "$old_mac" && "$old_mac" == "$new_mac" ]]; then
        log "INFO: iface=$iface already at target MAC; skip link flap"
        write_state "$iface" "$key" "$new_mac" "$(now_iso)"
        enforce_nm_cloned_mac
        return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: would down/change/up iface=$iface new_mac=$new_mac"
        # Write state even in dry-run so reuse tests can verify per-SSID pinning
        # without requiring root for a real MAC change. State is metadata, not
        # kernel state; writing it is safe.
        write_state "$iface" "$key" "$new_mac" "$(now_iso)"
        enforce_nm_cloned_mac
        return 0
    fi

    local err
    err="$(mktemp)"
    if ! ip link set dev "$iface" down 2>"$err"; then
        log "ERROR: ip link set $iface down failed: $(<"$err")"
        rm -f "$err"
        return 1
    fi
    if ! ip link set dev "$iface" address "$new_mac" 2>"$err"; then
        log "ERROR: ip link set $iface address failed: $(<"$err")"
        ip link set dev "$iface" up 2>/dev/null || true
        rm -f "$err"
        return 1
    fi
    if ! ip link set dev "$iface" up 2>"$err"; then
        log "ERROR: ip link set $iface up failed: $(<"$err")"
        rm -f "$err"
        return 1
    fi
    rm -f "$err"

    # Verify the kernel actually accepted the new MAC. Broadcom brcmfmac
    # and some Realtek drivers silently ignore address changes; without
    # this check the daemon would log "OK" while the link keeps the
    # previous MAC.
    actual_mac="$(ip -o link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {for(i=1;i<=NF;i++) if($i=="link/ether") {print $(i+1); exit}}')"
    if [[ "$actual_mac" != "$new_mac" ]]; then
        log "ERROR: iface=$iface post-set MAC mismatch: expected=$new_mac got=$actual_mac; driver rejected change"
        return 1
    fi

    if [[ "$STABILIZE_IPV6" == "true" ]]; then
        sysctl -qw "net.ipv6.conf.${iface}.addr_gen_mode=1" 2>/dev/null || \
            log "WARN: sysctl addr_gen_mode=1 for $iface failed"
    fi

    enforce_nm_cloned_mac
    write_state "$iface" "$key" "$new_mac" "$(now_iso)"
    log "iface=$iface MAC change OK: $old_mac -> $new_mac"
    return 0
}

# ----- Main loop -----
trigger="$MODE"

ifaces=()
if [[ "$MODE" == "connection" ]]; then
    ifaces=("$IFACE")
elif [[ -n "${DEMON_MAC_FAKE_IFACES:-}" ]]; then
    # Test-only: override the iface list (otherwise we'd need a real iface).
    IFS=',' read -ra ifaces <<<"$DEMON_MAC_FAKE_IFACES"
else
    while IFS= read -r line; do
        iface=$(awk '{print $2}' <<<"$line" | tr -d ':')
        [[ -n "$iface" ]] && ifaces+=("$iface")
    done < <(ip -o link show 2>/dev/null | awk '/link\/ether/ {print}')
fi

processed=0
skipped=0
unchanged=0
failed=0
for iface in "${ifaces[@]}"; do
    [[ -z "$iface" ]] && continue
    if ! in_targets "$iface"; then
        log "iface $iface not in TARGETS; skip"
        skipped=$((skipped + 1))
        continue
    fi
    if ! is_physical "$iface"; then
        log "iface $iface not physical; skip"
        skipped=$((skipped + 1))
        continue
    fi

    case "$MANAGEMENT_MODE" in
        supervisor)
            apply_nm_supervisor "$iface"
            processed=$((processed + 1))
            ;;
        daemon|hybrid)
            key="$(lookup_key "$trigger" "$SSID")"

            # For non-connection policies, restore state-recorded MAC if it
            # drifted (e.g. NM reverted between daemon runs).
            if [[ "$trigger" != "connection" ]]; then
                reconcile_iface "$iface" "$key"
            fi

            if ! should_rotate "$iface" "$SSID" "$trigger"; then
                log "iface $iface key='$key' no rotation needed (trigger=$trigger policy=$ROTATION_POLICY); skip"
                unchanged=$((unchanged + 1))
                continue
            fi

            # In hybrid mode, also supervise the profile before the
            # kernel-direct MAC write so NM doesn't fight us mid-call.
            if [[ "$MANAGEMENT_MODE" == "hybrid" ]]; then
                apply_nm_supervisor "$iface"
            fi

            if apply_change "$iface" "$key"; then
                processed=$((processed + 1))
            else
                failed=$((failed + 1))
            fi
            ;;
    esac
done

log "summary: processed=$processed skipped=$skipped unchanged=$unchanged failed=$failed"

exit 0