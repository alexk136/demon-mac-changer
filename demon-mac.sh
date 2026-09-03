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
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"
STABILIZE_IPV6="${STABILIZE_IPV6:-true}"
MAC_PREFIX="${MAC_PREFIX:-}"

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

log "config: policy=$ROTATION_POLICY pin=$PIN_MODE targets='$TARGETS' prefix='$MAC_PREFIX' state=$STATE_FILE"

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
    local trigger="$1" ssid="$3"
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
        hex="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
        printf '%s:%s:%s:%s:%s:%s\n' \
            "${MAC_PREFIX:0:2}" "${MAC_PREFIX:3:2}" \
            "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}"
    else
        # Full random; first byte forced to 0x02 (locally-administered + unicast + individual).
        hex="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
        printf '02:%s:%s:%s:%s:%s:%s\n' \
            "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}" "${hex:10:2}"
    fi
}

# ----- State management -----
# State file formats (read both, write always new):
#   legacy:  iface|mac|ts            (3 columns)
#   new:     iface|ssid|mac|ts       (4 columns, ssid may be empty for boot-pin)
#
# read_state_mac_for(iface, key): key is SSID or empty.
# Tries (iface, key) first; falls back to (iface, "") new entry;
# falls back to legacy iface-only entry.
read_state_mac_for() {
    local iface="$1" key="$2"
    [[ -r "$STATE_FILE" ]] || return 1
    local entry

    if [[ -n "$key" ]]; then
        entry="$(grep "^${iface}|${key}|" "$STATE_FILE" 2>/dev/null | head -1)"
        if [[ -n "$entry" ]]; then
            cut -d'|' -f3 <<<"$entry"
            return 0
        fi
    fi

    # New format with empty key: iface||mac|ts
    entry="$(grep "^${iface}||" "$STATE_FILE" 2>/dev/null | head -1)"
    if [[ -n "$entry" ]]; then
        cut -d'|' -f3 <<<"$entry"
        return 0
    fi

    # Legacy format: iface|mac|ts (3 fields)
    local line nfields entry_iface
    while IFS= read -r line; do
        nfields="$(awk -F'|' '{print NF}' <<<"$line")"
        if [[ "$nfields" -eq 3 ]]; then
            entry_iface="$(cut -d'|' -f1 <<<"$line")"
            if [[ "$entry_iface" == "$iface" ]]; then
                cut -d'|' -f2 <<<"$line"
                return 0
            fi
        fi
    done < "$STATE_FILE"

    return 1
}

read_state_ts_for() {
    local iface="$1" key="$2"
    [[ -r "$STATE_FILE" ]] || return 1
    local entry

    if [[ -n "$key" ]]; then
        entry="$(grep "^${iface}|${key}|" "$STATE_FILE" 2>/dev/null | head -1)"
        if [[ -n "$entry" ]]; then
            cut -d'|' -f4 <<<"$entry"
            return 0
        fi
    fi

    entry="$(grep "^${iface}||" "$STATE_FILE" 2>/dev/null | head -1)"
    if [[ -n "$entry" ]]; then
        cut -d'|' -f4 <<<"$entry"
        return 0
    fi

    local line nfields entry_iface
    while IFS= read -r line; do
        nfields="$(awk -F'|' '{print NF}' <<<"$line")"
        if [[ "$nfields" -eq 3 ]]; then
            entry_iface="$(cut -d'|' -f1 <<<"$line")"
            if [[ "$entry_iface" == "$iface" ]]; then
                cut -d'|' -f3 <<<"$line"
                return 0
            fi
        fi
    done < "$STATE_FILE"

    return 1
}

write_state() {
    local iface="$1" key="$2" mac="$3" ts="$4"
    local dir tmp
    dir="$(dirname "$STATE_FILE")"
    [[ -d "$dir" ]] || mkdir -p -m 700 "$dir"
    tmp="$(mktemp -p "$dir" .state.XXXXXX)"

    if [[ -r "$STATE_FILE" ]]; then
        local line nfields entry_iface entry_key
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            nfields="$(awk -F'|' '{print NF}' <<<"$line")"
            entry_iface="$(cut -d'|' -f1 <<<"$line")"
            if [[ "$entry_iface" == "$iface" ]]; then
                if [[ "$nfields" -eq 4 ]]; then
                    # New format: replace if (iface, ssid) matches the write key
                    entry_key="$(cut -d'|' -f2 <<<"$line")"
                    if [[ "$entry_key" == "$key" ]]; then
                        continue
                    fi
                elif [[ "$nfields" -eq 3 ]]; then
                    # Legacy: replace only if writing boot-pin (empty key)
                    if [[ -z "$key" ]]; then
                        continue
                    fi
                fi
            fi
            printf '%s\n' "$line"
        done < "$STATE_FILE" >> "$tmp"
    fi

    printf '%s|%s|%s|%s\n' "$iface" "$key" "$mac" "$ts" >> "$tmp"
    chmod 644 "$tmp"
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
    key="$(lookup_key "$trigger" "$iface" "$ssid")"

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

# ----- Apply MAC change -----
apply_change() {
    local iface="$1" key="$2"
    local new_mac old_mac
    new_mac="$(generate_mac)"
    old_mac="$(ip -o link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $(NF-1)}')"

    log "iface=$iface key='$key' old_mac=$old_mac new_mac=$new_mac"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: would down/change/up iface=$iface new_mac=$new_mac"
        # Write state even in dry-run so reuse tests can verify per-SSID pinning
        # without requiring root for a real MAC change. State is metadata, not
        # kernel state; writing it is safe.
        write_state "$iface" "$key" "$new_mac" "$(now_iso)"
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

    if [[ "$STABILIZE_IPV6" == "true" ]]; then
        sysctl -qw "net.ipv6.conf.${iface}.addr_gen_mode=1" 2>/dev/null || \
            log "WARN: sysctl addr_gen_mode=1 for $iface failed"
    fi

    write_state "$iface" "$key" "$new_mac" "$(now_iso)"
    log "iface=$iface MAC change OK: $old_mac -> $new_mac"
    return 0
}

# ----- Main loop -----
trigger="$MODE"

ifaces=()
if [[ "$MODE" == "connection" ]]; then
    ifaces=("$IFACE")
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
    key="$(lookup_key "$trigger" "$iface" "$SSID")"
    if ! should_rotate "$iface" "$SSID" "$trigger"; then
        log "iface $iface key='$key' no rotation needed (trigger=$trigger policy=$ROTATION_POLICY); skip"
        unchanged=$((unchanged + 1))
        continue
    fi
    if apply_change "$iface" "$key"; then
        processed=$((processed + 1))
    else
        failed=$((failed + 1))
    fi
done

log "summary: processed=$processed skipped=$skipped unchanged=$unchanged failed=$failed"

exit 0