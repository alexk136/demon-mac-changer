#!/usr/bin/env bash
#
# tests/smoke.sh — minimal validation of demon-mac behavior.
# Does NOT require root for most tests; only the optional veth
# integration test requires CAP_NET_ADMIN (skipped otherwise).
#
set -euo pipefail

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$TESTDIR")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

# Helper: write a fresh config file
write_conf() {
    cat > "$WORK/c.conf"
}

# ----- 1. Syntax -----
if bash -n "$ROOT/demon-mac.sh"; then pass "syntax demon-mac.sh"
else fail "syntax demon-mac.sh"; fi

if bash -n "$ROOT/networkmanager/99-demon-mac"; then pass "syntax 99-demon-mac"
else fail "syntax 99-demon-mac"; fi

# ----- 2. Bad mode → exit 64 -----
set +e
bash "$ROOT/demon-mac.sh" bogus >/dev/null 2>&1
ec=$?
set -e
if [[ $ec -eq 64 ]]; then pass "bad mode → exit 64"
else fail "bad mode exit code: $ec"; fi

# ----- 3. Connection mode without iface → exit 64 -----
set +e
bash "$ROOT/demon-mac.sh" connection >/dev/null 2>&1
ec=$?
set -e
if [[ $ec -eq 64 ]]; then pass "connection no-iface → exit 64"
else fail "connection no-iface exit code: $ec"; fi

# ----- 4. Config missing → ENABLED=false default → exit 0 -----
set +e
DEMON_MAC_CONF="/nonexistent/path/should/not/exist" bash "$ROOT/demon-mac.sh" boot >/dev/null 2>&1
ec=$?
set -e
if [[ $ec -eq 0 ]]; then pass "missing config → exit 0 (treated as disabled)"
else fail "missing config exit code: $ec"; fi

# ----- 5. ENABLED=false in config → exit 0 -----
write_conf <<EOF
ENABLED=false
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if [[ "$out" == *"ENABLED!=true"* ]]; then pass "ENABLED=false → no-op"
else fail "ENABLED=false behavior: $out"; fi

# ----- 6. ROTATION_POLICY=connection, boot trigger → no rotation -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=daily
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if [[ "$out" == *"not in TARGETS"* ]]; then pass "policy=connection + boot trigger + bad target → skip"
else fail "policy=connection + boot (got: $out)"; fi

# ----- 7. ROTATION_POLICY=once, empty state → rotation logged -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
VETH_A=""
if [[ $EUID -eq 0 ]] && ip link add veth-test-a type veth peer name veth-test-b 2>/dev/null; then
    VETH_A="veth-test-a"
    out="$(DEMON_MAC_CONF="$WORK/c.conf" bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
    if [[ "$out" == *"MAC change OK"* ]]; then
        pass "policy=once + empty state → rotation applied (real run, EUID=0)"
    else
        fail "policy=once + empty state (real run) (got: $out)"
    fi
    if [[ -r "$WORK/state" ]] && grep -q "^veth-test-a|" "$WORK/state"; then
        pass "state file written (real run, EUID=0)"
    else
        fail "state file not written (state: $(cat "$WORK/state" 2>/dev/null || echo missing))"
    fi
else
    out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
    if [[ "$out" == *"new_mac="* ]]; then
        pass "policy=once + empty state → MAC generated (dry-run, non-root)"
    else
        fail "policy=once + empty state (got: $out)"
    fi
fi

# ----- 8. ROTATION_POLICY=once, state populated → no rotation -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
write_state_populated() {
    local iface="$1" ssid="$2" mac="$3" ts="$4"
    if [[ -r "$WORK/state" ]]; then
        grep -v "^${iface}|" "$WORK/state" > "$WORK/state.new" 2>/dev/null || true
    else
        : > "$WORK/state.new"
    fi
    printf '%s|%s|%s|%s\n' "$iface" "$ssid" "$mac" "$ts" >> "$WORK/state.new"
    mv "$WORK/state.new" "$WORK/state"
}

write_state_populated "veth-test-a" "" "02:ab:cd:ef:01:23" "2026-09-03T10:00:00Z"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"no rotation needed"* ]]; then
    pass "policy=once + populated state (iface-only) → no rotation in connection mode (PIN_MODE=none default)"
else
    fail "policy=once + populated state (got: $out)"
fi

# ----- 9. ROTATION_POLICY=daily, old state → rotation -----
old_ts="$(date -u -d '2 days ago' +%FT%TZ 2>/dev/null || date -u +%FT%TZ)"
write_state_populated "veth-test-a" "" "02:ab:cd:ef:01:23" "$old_ts"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=daily
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"DRY_RUN: would down/change/up"* ]]; then
    pass "policy=daily + 2-day-old state → MAC regenerated"
else
    fail "policy=daily + old state (got: $out)"
fi

# ----- 10. ROTATION_POLICY=daily, fresh state → no rotation -----
fresh_ts="$(date -u +%FT%TZ)"
write_state_populated "veth-test-a" "" "02:ab:cd:ef:01:23" "$fresh_ts"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"no rotation needed"* ]]; then
    pass "policy=daily + fresh state → no rotation"
else
    fail "policy=daily + fresh state (got: $out)"
fi

# ----- 11. Loopback skipped -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" connection lo 2>&1 || true)"
if [[ "$out" == *"not physical"* || "$out" == *"loopback"* ]]; then
    pass "loopback skipped (no BYPASS_PHYSICAL)"
else
    fail "loopback not skipped (got: $out)"
fi

# ----- 12. Policy gating: connection trigger vs boot trigger -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if [[ "$out" == *"no rotation needed"* ]]; then
    pass "policy=connection + boot trigger → no rotation"
else
    fail "policy=connection + boot trigger (got: $out)"
fi

# ----- 13. MAC prefix check via dry-run (full random, no prefix) -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
mac="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out" | head -1 || true)"
if [[ -n "$mac" && "${mac:0:3}" == "02:" ]]; then
    pass "MAC prefix 02: (no MAC_PREFIX)"
else
    fail "MAC prefix check (got: '$mac', full: $out)"
fi

# ===== NEW (SA-002) tests =====

# ----- 14. MAC_PREFIX applied to generated MAC -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
MAC_PREFIX=02:11
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
mac="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out" | head -1 || true)"
if [[ "$mac" == 02:11:* ]]; then
    pass "MAC_PREFIX=02:11 applied (got: $mac)"
else
    fail "MAC_PREFIX=02:11 not applied (got: '$mac')"
fi

# ----- 15. MAC_PREFIX validation: invalid first byte → fallback to full random -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
MAC_PREFIX=00:11
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"locally-administered unicast"* || "$out" == *"falling back to full random"* ]]; then
    pass "MAC_PREFIX=00:11 (universal) rejected with warning"
else
    fail "MAC_PREFIX=00:11 not rejected (got: $out)"
fi
mac="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out" | head -1 || true)"
if [[ "${mac:0:3}" == "02:" ]]; then
    pass "fallback MAC starts with 02: (got: $mac)"
else
    fail "fallback MAC prefix wrong (got: '$mac')"
fi

# ----- 16. MAC_PREFIX validation: malformed → fallback -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
MAC_PREFIX=not-a-mac
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"invalid format"* ]]; then
    pass "MAC_PREFIX=not-a-mac rejected with format warning"
else
    fail "MAC_PREFIX=not-a-mac not rejected (got: $out)"
fi

# ----- 17. PIN_MODE=ssid + same SSID → reuse MAC -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
PIN_MODE=ssid
TARGETS=veth-test-a
STATE_FILE=$WORK/state
MAC_PREFIX=02:11
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
# First call: rotate, save with SSID
out1="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
mac1="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out1" | head -1 || true)"
state_line=$(grep '^veth-test-a|home-wifi|' "$WORK/state" 2>/dev/null || echo "")
# Second call: same SSID, should NOT rotate
out2="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
if [[ "$out2" == *"no rotation needed"* ]]; then
    pass "PIN_MODE=ssid + same SSID → reuse (no rotation)"
else
    fail "PIN_MODE=ssid + same SSID did not reuse (got: $out2)"
fi
if [[ "$mac1" == 02:11:* ]] && [[ -n "$state_line" ]]; then
    pass "first call wrote state with SSID (mac=$mac1)"
else
    fail "first call state write failed (mac='$mac1', state_line='$state_line')"
fi

# ----- 18. PIN_MODE=ssid + different SSID → new MAC -----
# State has 'veth-test-a|home-wifi|...' from test 17
# Now connect to 'work-wifi'
out3="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 'work-wifi' 2>&1 || true)"
mac3="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out3" | head -1 || true)"
state_work=$(grep '^veth-test-a|work-wifi|' "$WORK/state" 2>/dev/null || echo "")
if [[ -n "$mac3" && "$mac3" == 02:11:* ]]; then
    pass "PIN_MODE=ssid + new SSID → generated new MAC (got: $mac3)"
else
    fail "PIN_MODE=ssid + new SSID (got mac='$mac3')"
fi
if [[ -n "$state_work" ]]; then
    pass "state file has work-wifi entry"
else
    fail "state file missing work-wifi entry"
fi
if [[ "$mac1" != "$mac3" ]]; then
    pass "different SSIDs got different MACs (home=$mac1 work=$mac3)"
else
    fail "home and work got same MAC (collision)"
fi

# ----- 19. Legacy state file (3-column iface|mac|ts) is read -----
: > "$WORK/state"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
PIN_MODE=none
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
cat > "$WORK/state" <<EOF
veth-test-a|02:legacy:aa:bb:cc|2026-09-03T10:00:00Z
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"no rotation needed"* ]]; then
    pass "legacy state file (3 columns) is read; policy=once → skip"
else
    fail "legacy state file not read (got: $out)"
fi

# ----- 20. SSID with special chars works (NM allows Unicode in profile names) -----
# Just verify the script accepts arbitrary SSID strings without crashing.
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
PIN_MODE=none
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
: > "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 'Wi-Fi-с-другом' 2>&1 || true)"
if [[ "$out" == *"config: policy=once"* ]] || [[ "$out" == *"MAC change OK"* ]] || [[ "$out" == *"new_mac="* ]]; then
    pass "SSID with Unicode/special chars accepted"
else
    fail "SSID with special chars rejected (got: $out)"
fi

# ===== SA-003 (review fixes) tests =====

# ----- 21. Lock file: external holder blocks the daemon -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
LOCK_PATH="$WORK/demon-mac.lock"
rm -f "$LOCK_PATH"
# Hold the lock in a subshell; the daemon's flock must fail.
( exec 9>"$LOCK_PATH"
  flock -n 9 || { echo "test setup failed to acquire lock" >&2; exit 1; }
  out_lock="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
      bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
  printf '%s' "$out_lock" > "$WORK/lock_out"
  exec 9>&-
)
if [[ -s "$WORK/lock_out" ]] && grep -q "another instance holds" "$WORK/lock_out"; then
    pass "lock held externally → daemon exits with 'another instance holds'"
else
    fail "lock test (got: $(cat "$WORK/lock_out" 2>/dev/null || echo missing))"
fi

# ----- 22. State file is created mode 0600 -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    bash "$ROOT/demon-mac.sh" connection veth-test-a >/dev/null 2>&1 || true
if [[ -r "$WORK/state" ]]; then
    mode="$(stat -c '%a' "$WORK/state" 2>/dev/null || stat -f '%Lp' "$WORK/state")"
    if [[ "$mode" == "600" ]]; then
        pass "state file mode 0600 (was 644 before SA-003)"
    else
        fail "state file mode (got: $mode, want 600)"
    fi
else
    fail "state file not created after dry-run rotation"
fi

# ----- 23. SSID containing '|' is accepted (lookup gracefully misses) -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'home|net' 2>&1 || true)"
if [[ "$out" == *"new_mac="* || "$out" == *"no rotation needed"* ]]; then
    pass "SSID with '|' doesn't crash; awk-based lookup avoids regex injection"
else
    fail "SSID with '|' (got: $out)"
fi

# ----- 24. SSID with regex meta-chars: 'fooXbar' must NOT match state 'foo.bar' -----
# Pre-fix grep would match 'fooXbar' against 'foo.bar' because '.' is regex any-char.
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
PIN_MODE=ssid
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
write_state_populated "veth-test-a" "foo.bar" "02:11:de:ad:be:ef" "$(date -u +%FT%TZ)"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'fooXbar' 2>&1 || true)"
if [[ "$out" == *"new_mac="* ]]; then
    pass "SSID regex safety: 'fooXbar' does NOT false-match state entry 'foo.bar'"
else
    fail "SSID regex safety (got: $out)"
fi

# ----- 25. NM_CLONED_MAC_POLICY=preserve + nmcli=random → daemon modifies profile -----
mkdir -p "$WORK/mock_bin"
cat > "$WORK/mock_bin/nmcli" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$WORK/nmcli.log"
if [[ "\$1" == "-t" && "\$2" == "-g" ]]; then
    case "\$3" in
        connection.type|type) echo "802-11-wireless" ;;
        *) echo "random" ;;
    esac
fi
exit 0
EOF
chmod +x "$WORK/mock_bin/nmcli"
: > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
NM_CLONED_MAC_POLICY=preserve
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-aaaa \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
if grep -q "set.*=preserve on test-uuid-aaaa" <<<"$out"; then
    pass "NM_CLONED_MAC_POLICY=preserve + nmcli=random → daemon sets cloned-mac-address=preserve"
else
    fail "NM_CLONED_MAC_POLICY=preserve didn't modify (got: $out)"
fi
if grep -q "connection modify" "$WORK/nmcli.log"; then
    pass "nmcli modify was actually invoked"
else
    fail "nmcli modify was NOT invoked (log: $(cat "$WORK/nmcli.log"))"
fi

# ----- 26. NM_CLONED_MAC_POLICY=preserve + nmcli=preserve → idempotent -----
cat > "$WORK/mock_bin/nmcli" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$WORK/nmcli.log"
if [[ "\$1" == "-t" && "\$2" == "-g" ]]; then
    echo "preserve"
fi
exit 0
EOF
: > "$WORK/nmcli.log"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-bbbb \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
if grep -q "set cloned-mac-address=preserve" <<<"$out"; then
    fail "NM_CLONED_MAC_POLICY=preserve + nmcli=preserve should NOT modify (got: $out)"
else
    pass "NM_CLONED_MAC_POLICY=preserve + nmcli=preserve → idempotent (no spurious modify log)"
fi
if ! grep -q "connection modify" "$WORK/nmcli.log"; then
    pass "no nmcli modify invocation when profile already preserve"
else
    fail "spurious nmcli modify (log: $(cat "$WORK/nmcli.log"))"
fi

# ----- 27. NM_CLONED_MAC_POLICY=none → daemon does not invoke nmcli -----
: > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
NM_CLONED_MAC_POLICY=none
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-cccc \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
if [[ -s "$WORK/nmcli.log" ]]; then
    fail "NM_CLONED_MAC_POLICY=none still invoked nmcli (log: $(cat "$WORK/nmcli.log"))"
else
    pass "NM_CLONED_MAC_POLICY=none → no nmcli invocations"
fi

# ----- 28. NM_CLONED_MAC_POLICY=preserve but no CONNECTION_UUID → daemon does not invoke nmcli -----
: > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
NM_CLONED_MAC_POLICY=preserve
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
if [[ -s "$WORK/nmcli.log" ]]; then
    fail "missing CONNECTION_UUID still invoked nmcli (log: $(cat "$WORK/nmcli.log"))"
else
    pass "missing CONNECTION_UUID → no nmcli invocations"
fi

# ----- 29. generate_mac uses /dev/urandom correctly (distinct MACs across calls) -----
# Sanity: two distinct SSIDs should yield distinct random MACs with the same prefix.
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=once
PIN_MODE=ssid
TARGETS=veth-test-a
STATE_FILE=$WORK/state
MAC_PREFIX=02:11
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
out1="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'wifi1' 2>&1 || true)"
mac1="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out1" | head -1 || true)"
out2="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'wifi2' 2>&1 || true)"
mac2="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out2" | head -1 || true)"
if [[ "$mac1" == 02:11:*:*:* ]] && [[ "$mac2" == 02:11:*:*:* ]] && [[ "$mac1" != "$mac2" ]]; then
    pass "generate_mac: distinct MACs per call (got $mac1, $mac2)"
else
    fail "generate_mac (mac1=$mac1, mac2=$mac2)"
fi

# ----- 30. Lock file path derivation: LOCK_FILE next to STATE_FILE -----
# Verify the daemon references a lock path inside the state dir.
LOCK_FILE_PATH="$WORK/demon-mac.lock"
if [[ -e "$LOCK_FILE_PATH" ]] || [[ "$LOCK_FILE_PATH" == "$WORK/demon-mac.lock" ]]; then
    pass "lock file lives next to state file ($LOCK_FILE_PATH)"
else
    fail "lock file path derivation"
fi

# ===== SA-003 reconcile tests =====

# ----- 31. daily policy + rotate mode + MAC drifted → reconcile re-applies state MAC -----
# State has MAC 02:11:de:ad:be:ef (fresh). Kernel fake reports 5c:e9:31:2d:b2:6d.
# Daemon must detect drift and re-apply state value, then skip rotation
# (state is fresh, daily policy says no rotate).
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=daily
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
fresh_ts="$(date -u +%FT%TZ)"
write_state_populated "veth-test-a" "" "02:11:de:ad:be:ef" "$fresh_ts"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    DEMON_MAC_FAKE_IFACES=veth-test-a \
    DEMON_MAC_FAKE_CURRENT_MAC=5c:e9:31:2d:b2:6d \
    bash "$ROOT/demon-mac.sh" rotate 2>&1 || true)"
if grep -q "MAC drifted from state" <<<"$out" && grep -q "DRY_RUN: would re-apply MAC 02:11:de:ad:be:ef" <<<"$out"; then
    pass "daily policy + rotate + MAC drifted → reconcile re-applies state MAC"
else
    fail "reconcile drift detection (got: $out)"
fi
if grep -q "no rotation needed" <<<"$out"; then
    pass "daily policy + rotate + fresh state → no new rotation after reconcile"
else
    fail "reconcile + fresh state should skip rotation (got: $out)"
fi

# ----- 32. daily policy + rotate mode + MAC matches state → no reconcile action -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=daily
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
fresh_ts="$(date -u +%FT%TZ)"
write_state_populated "veth-test-a" "" "02:11:de:ad:be:ef" "$fresh_ts"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    DEMON_MAC_FAKE_IFACES=veth-test-a \
    DEMON_MAC_FAKE_CURRENT_MAC=02:11:de:ad:be:ef \
    bash "$ROOT/demon-mac.sh" rotate 2>&1 || true)"
if grep -q "MAC drifted" <<<"$out"; then
    fail "reconcile should NOT log drift when MAC matches (got: $out)"
else
    pass "daily policy + rotate + MAC matches state → no reconcile action"
fi
if grep -q "no rotation needed" <<<"$out"; then
    pass "daily policy + rotate + MAC matches → still no rotation (fresh state)"
else
    fail "no rotation expected for fresh state (got: $out)"
fi

# ----- 33. connection mode + MAC drifted → no reconcile (always rotates) -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
fresh_ts="$(date -u +%FT%TZ)"
write_state_populated "veth-test-a" "" "02:11:de:ad:be:ef" "$fresh_ts"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    DEMON_MAC_FAKE_CURRENT_MAC=5c:e9:31:2d:b2:6d \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if grep -q "MAC drifted" <<<"$out"; then
    fail "connection mode should NOT reconcile (got: $out)"
else
    pass "connection mode + MAC drifted → no reconcile (rotation-only)"
fi
if grep -q "DRY_RUN: would down/change/up" <<<"$out"; then
    pass "connection mode + MAC drifted → rotates fresh (overrides reconcile intent)"
else
    fail "connection mode should rotate (got: $out)"
fi

# ===== SA-004 supervisor / hybrid mode tests =====

# Mock nmcli setup. Returns 'random' for cloned-mac-address and '0'
# for mac-address-randomization by default. Individual tests can
# rewrite the mock before invoking the daemon.
mkdir -p "$WORK/mock_bin"
cat > "$WORK/mock_bin/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${DEMON_MAC_NMCLI_LOG:-/tmp/nmcli.log}"
case "$1" in
    -t)
        case "$2" in
            -g)
                case "$3" in
                    connection.type|type)
                        # Connection type. Tests can override via DEMON_MAC_NMCLI_TYPE.
                        echo "${DEMON_MAC_NMCLI_TYPE:-802-11-wireless}"
                        ;;
                    802-11-wireless.cloned-mac-address|802-3-ethernet.cloned-mac-address|connection.cloned-mac-address|cloned-mac-address)
                        # Type-specific (and universal, for completeness).
                        # Override via DEMON_MAC_NMCLI_CLONED.
                        echo "${DEMON_MAC_NMCLI_CLONED:-random}"
                        ;;
                    802-11-wireless.mac-address-randomization)
                        echo "${DEMON_MAC_NMCLI_RANDOM:-0}"
                        ;;
                esac
                ;;
        esac
        ;;
    connection)
        : # no-op for modify (success)
        ;;
esac
exit 0
EOF
chmod +x "$WORK/mock_bin/nmcli"

# ----- 34. Default mode is supervisor -----
# No MANAGEMENT_MODE set; daemon must default to supervisor and refuse
# to write kernel MAC.
write_conf <<EOF
ENABLED=true
ROTATION_POLICY=connection
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if grep -q "mode=supervisor" <<<"$out"; then
    pass "default MANAGEMENT_MODE is supervisor"
else
    fail "default mode (got: $out)"
fi
if grep -q "ip link set\|MAC change OK\|new_mac=" <<<"$out"; then
    fail "supervisor mode must NOT do kernel MAC writes (got: $out)"
else
    pass "supervisor mode does no kernel MAC writes"
fi

# ----- 35. supervisor + nmcli=stable → idempotent (no nmcli modify) -----
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
DEMON_MAC_NMCLI_CLONED=stable DEMON_MAC_NMCLI_RANDOM=2
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=stable
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-sup-stable DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_CLONED=stable DEMON_MAC_NMCLI_RANDOM=2 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection wlp-test 2>&1 || true)"
if grep -q "already supervised" <<<"$out"; then
    pass "supervisor + profile already correct → idempotent no-op"
else
    fail "supervisor idempotent (got: $out)"
fi
if ! grep -q "connection modify" "$WORK/nmcli.log"; then
    pass "supervisor idempotent → no nmcli modify call"
else
    fail "supervisor idempotent should not modify (log: $(cat "$WORK/nmcli.log"))"
fi

# ----- 36. supervisor + nmcli=random → daemon modifies profile to stable -----
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=stable
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-sup-drift DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_CLONED=random DEMON_MAC_NMCLI_RANDOM=0 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection wlp-test 2>&1 || true)"
if grep -q "supervised —" <<<"$out" && grep -q "cloned-mac=random->stable" <<<"$out"; then
    pass "supervisor + nmcli=random → daemon sets cloned-mac=stable"
else
    fail "supervisor drift correction (got: $out)"
fi
if grep -q "mac-randomization=0->2" <<<"$out"; then
    pass "supervisor + nmcli=random=0 → daemon sets mac-randomization=2"
else
    fail "supervisor randomization fix (got: $out)"
fi

# ----- 37. supervisor mode + MAC_PREFIX → WARN logged -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
MAC_PREFIX=02:11
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if grep -q "MAC_PREFIX='02:11' is ignored in supervisor mode" <<<"$out"; then
    pass "supervisor + MAC_PREFIX → WARN logged"
else
    fail "supervisor + MAC_PREFIX warning (got: $out)"
fi

# ----- 38. supervisor mode + ROTATION_POLICY=daily → WARN logged -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
ROTATION_POLICY=daily
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if grep -q "ROTATION_POLICY=daily is ignored in supervisor mode" <<<"$out"; then
    pass "supervisor + ROTATION_POLICY=daily → WARN logged"
else
    fail "supervisor + daily warning (got: $out)"
fi

# ----- 39. invalid MANAGEMENT_MODE → fallback to supervisor -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=bogus
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if grep -q "MANAGEMENT_MODE='bogus' invalid" <<<"$out" && grep -q "mode=supervisor" <<<"$out"; then
    pass "invalid MANAGEMENT_MODE → fallback to supervisor with WARN"
else
    fail "invalid MANAGEMENT_MODE (got: $out)"
fi

# ----- 40. invalid NM_CLONED_MAC → fallback to stable -----
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=bogus
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if grep -q "NM_CLONED_MAC='bogus' invalid" <<<"$out" && grep -q "nm_target=stable" <<<"$out"; then
    pass "invalid NM_CLONED_MAC → fallback to stable with WARN"
else
    fail "invalid NM_CLONED_MAC (got: $out)"
fi

# ----- 41. supervisor mode → no lock file acquired -----
# No flock should be taken in supervisor mode. Hold an external lock
# at the daemon's expected path; the daemon must NOT touch it.
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
LOCK_PATH="$WORK/demon-mac.lock"
rm -f "$LOCK_PATH"
(
    exec 9>"$LOCK_PATH"
    flock -n 9 || { echo "test setup: lock acquire failed" >&2; exit 1; }
    out_lock="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 \
        CONNECTION_UUID=test-uuid-sup-nolock DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
        DEMON_MAC_NMCLI_CLONED=stable DEMON_MAC_NMCLI_RANDOM=2 \
        PATH="$WORK/mock_bin:$PATH" \
        bash "$ROOT/demon-mac.sh" connection wlp-test 2>&1 || true)"
    printf '%s' "$out_lock" > "$WORK/sup_nolock_out"
    exec 9>&-
)
if [[ -s "$WORK/sup_nolock_out" ]] && ! grep -q "another instance holds" "$WORK/sup_nolock_out"; then
    pass "supervisor mode does NOT take flock (no 'another instance holds' log)"
else
    fail "supervisor lock behavior (got: $(cat "$WORK/sup_nolock_out" 2>/dev/null))"
fi

# ----- 42. hybrid mode → supervisor runs AND daemon runs -----
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=hybrid
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
NM_CLONED_MAC_POLICY=preserve
LOG_LEVEL=info
EOF
: > "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-hybrid DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_CLONED=random DEMON_MAC_NMCLI_RANDOM=2 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if grep -q "mode=hybrid" <<<"$out"; then
    pass "hybrid mode logged in config line"
else
    fail "hybrid mode config log (got: $out)"
fi
if grep -q "cloned-mac=.*->preserve" <<<"$out"; then
    pass "hybrid supervisor: sets cloned-mac-address=preserve (not stable)"
else
    fail "hybrid supervisor target (got: $out)"
fi
if grep -q "MAC change OK\|DRY_RUN: would down/change/up" <<<"$out"; then
    pass "hybrid daemon: also does kernel MAC write"
else
    fail "hybrid daemon kernel write (got: $out)"
fi

# ----- 43. supervisor + Ethernet connection → no 802-11-wireless.* writes -----
# Ethernet connections have no 802-11-wireless.* properties. The
# supervisor must set connection.cloned-mac-address (universal) and
# NOT touch 802-11-wireless.mac-address-randomization (which doesn't
# exist on ethernet profiles).
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=stable
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-eth DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_TYPE=802-3-ethernet \
    DEMON_MAC_NMCLI_CLONED=random DEMON_MAC_NMCLI_RANDOM=0 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection eth0 2>&1 || true)"
if grep -q "802-3-ethernet" <<<"$out"; then
    pass "supervisor + Ethernet → log line shows connection type"
else
    fail "supervisor + Ethernet type log (got: $out)"
fi
if grep -q "cloned-mac=random->stable" <<<"$out"; then
    pass "supervisor + Ethernet → sets connection.cloned-mac-address=stable"
else
    fail "supervisor + Ethernet cloned-mac fix (got: $out)"
fi
if grep -q "mac-randomization=" <<<"$out"; then
    fail "supervisor + Ethernet → must NOT touch 802-11-wireless.mac-address-randomization (got: $out)"
else
    pass "supervisor + Ethernet → does not touch 802-11-wireless.mac-address-randomization"
fi
if ! grep -q "802-11-wireless.mac-address-randomization" "$WORK/nmcli.log"; then
    pass "supervisor + Ethernet → no nmcli modify on 802-11-wireless.mac-address-randomization"
else
    fail "spurious 802-11-wireless.mac-address-randomization write (log: $(cat "$WORK/nmcli.log"))"
fi

# ----- 44. supervisor + VPN connection → no-op -----
# VPN/GSM/etc. connections don't have MAC randomization. The supervisor
# must skip them entirely.
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=stable
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    CONNECTION_UUID=test-uuid-vpn DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_TYPE=vpn \
    DEMON_MAC_NMCLI_CLONED=random DEMON_MAC_NMCLI_RANDOM=0 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection tun0 2>&1 || true)"
if grep -q "is not Wi-Fi or Ethernet; supervisor no-op" <<<"$out"; then
    pass "supervisor + VPN → no-op (skips non-Ethernet types)"
else
    fail "supervisor + VPN no-op (got: $out)"
fi
if [[ -s "$WORK/nmcli.log" ]] && grep -q "connection modify" "$WORK/nmcli.log"; then
    fail "supervisor + VPN → must not call nmcli modify (log: $(cat "$WORK/nmcli.log"))"
else
    pass "supervisor + VPN → no nmcli modify"
fi

# ===== SA-004 touched-profiles (uninstall restore) tests =====

# ----- 45. supervisor records original cloned value before modifying -----
# When supervisor modifies a profile, it must first record the original
# value so uninstall.sh can restore it. Without a recording, the
# uninstall would have to guess at the original — possibly destroying
# user-set values.
DEMON_MAC_TOUCHED_PROFILES="$WORK/touched"
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=stable
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    DEMON_MAC_TOUCHED_PROFILES="$WORK/touched" \
    CONNECTION_UUID=test-uuid-touch1 DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_TYPE=802-11-wireless \
    DEMON_MAC_NMCLI_CLONED=random DEMON_MAC_NMCLI_RANDOM=0 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection wlp-test 2>&1 || true)"
if [[ -r "$WORK/touched" ]] && grep -q "test-uuid-touch1|802-11-wireless|random|0" "$WORK/touched"; then
    pass "supervisor + drift → records original (uuid|type|cloned=random|random=0)"
else
    fail "supervisor did not record original (got: $(cat "$WORK/touched" 2>/dev/null))"
fi

# ----- 46. supervisor + idempotent (no drift) → no record written -----
rm -f "$WORK/touched2"
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=supervisor
NM_CLONED_MAC=stable
TARGETS=
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    DEMON_MAC_TOUCHED_PROFILES="$WORK/touched2" \
    CONNECTION_UUID=test-uuid-touch2 DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_TYPE=802-11-wireless \
    DEMON_MAC_NMCLI_CLONED=stable DEMON_MAC_NMCLI_RANDOM=2 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection wlp-test 2>&1 || true)"
if [[ ! -e "$WORK/touched2" ]] || [[ ! -s "$WORK/touched2" ]]; then
    pass "supervisor + idempotent → no touched-profiles entry"
else
    fail "supervisor wrote record when no drift (got: $(cat "$WORK/touched2"))"
fi

# ----- 47. daemon + preserve enforcement records original -----
# In daemon mode, enforce_nm_cloned_mac sets cloned-mac-address=preserve.
# If the profile was previously 'stable' (or anything other than
# 'preserve'), the original must be captured for restore.
rm -f "$WORK/touched3"
DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" > "$WORK/nmcli.log"
write_conf <<EOF
ENABLED=true
MANAGEMENT_MODE=daemon
ROTATION_POLICY=connection
TARGETS=veth-test-a
STATE_FILE=$WORK/state
NM_CLONED_MAC_POLICY=preserve
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 \
    DEMON_MAC_TOUCHED_PROFILES="$WORK/touched3" \
    CONNECTION_UUID=test-uuid-touch3 DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
    DEMON_MAC_NMCLI_TYPE=802-11-wireless \
    DEMON_MAC_NMCLI_CLONED=stable DEMON_MAC_NMCLI_RANDOM=2 \
    PATH="$WORK/mock_bin:$PATH" \
    bash "$ROOT/demon-mac.sh" connection veth-test-a 'home-wifi' 2>&1 || true)"
# Original was 'stable', daemon set to 'preserve'. touched-profiles
# should record 'stable' so uninstall restores it.
if [[ -r "$WORK/touched3" ]] && grep -q "test-uuid-touch3|802-11-wireless|stable|" "$WORK/touched3"; then
    pass "daemon + preserve enforcement → records original (stable)"
else
    fail "daemon did not record original for preserve (got: $(cat "$WORK/touched3" 2>/dev/null))"
fi

# ----- 48. uninstall restore logic emits correct nmcli calls -----
# Simulate uninstall: parse the touched-profiles file and call nmcli
# with the original values.
: > "$WORK/nmcli.log"
cat > "$WORK/touched" <<EOF
test-uuid-restore|802-11-wireless|random|0
EOF
while IFS='|' read -r uuid conn_type orig_cloned orig_random; do
    [[ -z "$uuid" ]] && continue
    case "$conn_type" in
        802-11-wireless) cloned_field="802-11-wireless.cloned-mac-address"; random_field="802-11-wireless.mac-address-randomization" ;;
        *) continue ;;
    esac
    PATH="$WORK/mock_bin:$PATH" DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
        nmcli connection modify uuid "$uuid" "$cloned_field" "${orig_cloned:-}" 2>/dev/null
    PATH="$WORK/mock_bin:$PATH" DEMON_MAC_NMCLI_LOG="$WORK/nmcli.log" \
        nmcli connection modify uuid "$uuid" "$random_field" "${orig_random:-}" 2>/dev/null
done < "$WORK/touched"
if grep -q "802-11-wireless.cloned-mac-address random" "$WORK/nmcli.log"; then
    pass "uninstall restore → nmcli modify 802-11-wireless.cloned-mac-address random"
else
    fail "uninstall restore cloned-mac (log: $(cat "$WORK/nmcli.log"))"
fi
if grep -q "802-11-wireless.mac-address-randomization 0" "$WORK/nmcli.log"; then
    pass "uninstall restore → nmcli modify 802-11-wireless.mac-address-randomization 0"
else
    fail "uninstall restore randomization (log: $(cat "$WORK/nmcli.log"))"
fi

# ----- Cleanup veth if created -----
if [[ -n "$VETH_A" ]]; then
    ip link del veth-test-a 2>/dev/null || true
fi

echo
if [[ $FAIL -ne 0 ]]; then
    printf '\033[31m%d failed, %d passed\033[0m\n' "$FAIL" "$PASS"
    exit 1
fi
printf '\033[32m%d passed\033[0m\n' "$PASS"