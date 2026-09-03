#!/usr/bin/env bash
#
# demon-mac.sh — MAC address randomizer daemon entrypoint.
#
# Modes:
#   boot       — invoked at boot via demon-mac-boot.service
#   connection — invoked on NetworkManager pre-up via dispatcher
#   rotate     — invoked periodically via demon-mac-rotate.timer
#
# All behavior controlled via /etc/demon-mac.conf.
#
# Environment:
#   DEMON_MAC_CONF       — override config path (default: /etc/demon-mac.conf)
#   DEMON_MAC_DRY_RUN=1  — log new MAC and state changes; skip actual ip link set
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
    local msg="mode=${MODE:-?} iface=${IFACE:-?} $*"
    logger -t demon-mac -p "user.${prio}" -- "$msg" 2>/dev/null || true
    printf '%s\n' "$msg" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s %s\n' "$(date -u +%FT%TZ)" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ----- Argument parsing -----
MODE="${1:-boot}"
IFACE="${2:-}"

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
TARGETS="${TARGETS:-}"
STATE_FILE="${STATE_FILE:-/var/lib/demon-mac/state}"
LOG_LEVEL="${LOG_LEVEL:-info}"
LOG_FILE="${LOG_FILE:-}"
STABILIZE_IPV6="${STABILIZE_IPV6:-true}"

log "config: policy=$ROTATION_POLICY targets='$TARGETS' state=$STATE_FILE"

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
    # Bypass for tests: trust caller's choice of iface.
    [[ "${DEMON_MAC_BYPASS_PHYSICAL:-0}" == "1" ]] && return 0
    [[ "$iface" == "lo" ]] && return 1
    [[ -e "/sys/class/net/$iface/device" ]] || return 1
    ip link show dev "$iface" &>/dev/null || return 1
    return 0
}

# ----- MAC generation -----
generate_mac() {
    local hex
    hex="$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n')"
    # hex is 10 hex chars (5 bytes). First byte = 02: unicast, locally-administered, individual
    printf '02:%s:%s:%s:%s:%s\n' \
        "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}"
}

# ----- State management -----
read_state_field() {
    local iface="$1" field="$2"
    [[ -r "$STATE_FILE" ]] || return 1
    local line
    line="$(grep "^${iface}|" "$STATE_FILE" 2>/dev/null | head -1)"
    [[ -z "$line" ]] && return 1
    case "$field" in
        mac) cut -d'|' -f2 <<<"$line" ;;
        ts)  cut -d'|' -f3 <<<"$line" ;;
        *)   return 1 ;;
    esac
}

write_state() {
    local iface="$1" mac="$2" ts="$3"
    local dir tmp
    dir="$(dirname "$STATE_FILE")"
    [[ -d "$dir" ]] || mkdir -p -m 700 "$dir"
    tmp="$(mktemp -p "$dir" .state.XXXXXX)"
    if [[ -r "$STATE_FILE" ]]; then
        grep -v "^${iface}|" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    fi
    printf '%s|%s|%s\n' "$iface" "$mac" "$ts" >> "$tmp"
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

# ----- Decision: should this iface be rotated now? -----
should_rotate() {
    local iface="$1" trigger="$2"
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
            last="$(read_state_field "$iface" mac || true)"
            [[ -z "$last" ]] && return 0
            return 1
            ;;
        daily)
            local last_ts age
            last_ts="$(read_state_field "$iface" ts || true)"
            [[ -z "$last_ts" ]] && return 0
            age="$(age_seconds "$last_ts")"
            (( age > 86400 )) && return 0
            return 1
            ;;
        weekly)
            local last_ts age
            last_ts="$(read_state_field "$iface" ts || true)"
            [[ -z "$last_ts" ]] && return 0
            age="$(age_seconds "$last_ts")"
            (( age > 604800 )) && return 0
            return 1
            ;;
        monthly)
            local last_ts age
            last_ts="$(read_state_field "$iface" ts || true)"
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
    local iface="$1"
    local new_mac old_mac
    new_mac="$(generate_mac)"
    old_mac="$(ip -o link show dev "$iface" 2>/dev/null | awk '/link\/ether/ {print $(NF-1)}')"

    log "iface=$iface old_mac=$old_mac new_mac=$new_mac"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY_RUN: would down/change/up iface=$iface new_mac=$new_mac"
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

    write_state "$iface" "$new_mac" "$(now_iso)"
    log "iface=$iface MAC change OK: $old_mac -> $new_mac"
    return 0
}

# ----- Main loop -----
trigger="$MODE"

ifaces=()
if [[ "$MODE" == "connection" ]]; then
    ifaces=("$IFACE")
else
    # boot / rotate — iterate all interfaces with link/ether
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
    if ! should_rotate "$iface" "$trigger"; then
        log "iface $iface no rotation needed (trigger=$trigger policy=$ROTATION_POLICY); skip"
        unchanged=$((unchanged + 1))
        continue
    fi
    if apply_change "$iface"; then
        processed=$((processed + 1))
    else
        failed=$((failed + 1))
    fi
done

log "summary: processed=$processed skipped=$skipped unchanged=$unchanged failed=$failed"

exit 0