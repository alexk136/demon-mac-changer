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
cat > "$WORK/c.conf" <<EOF
ENABLED=false
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if [[ "$out" == *"ENABLED!=true"* ]]; then pass "ENABLED=false → no-op"
else fail "ENABLED=false behavior: $out"; fi

# ----- 6. ROTATION_POLICY=connection, boot trigger → no rotation -----
cat > "$WORK/c.conf" <<EOF
ENABLED=true
ROTATION_POLICY=connection
TARGETS=zzz_nonexistent_iface_12345
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 bash "$ROOT/demon-mac.sh" boot 2>&1 || true)"
if [[ "$out" == *"not in TARGETS"* ]]; then pass "policy=connection + boot trigger + bad target → skip"
else fail "policy=connection + boot (got: $out)"; fi

# ----- 7. ROTATION_POLICY=once, empty state → rotation logged -----
cat > "$WORK/c.conf" <<EOF
ENABLED=true
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
# Use veth so we don't touch real interfaces. Create veth pair if root.
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
    # Non-root: dry-run with BYPASS_PHYSICAL since veth-test-a doesn't exist
    out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
    if [[ "$out" == *"new_mac="* ]]; then
        pass "policy=once + empty state → MAC generated (dry-run, non-root)"
    else
        fail "policy=once + empty state (got: $out)"
    fi
fi

# ----- 8. ROTATION_POLICY=once, state populated → no rotation -----
cat > "$WORK/state" <<EOF
veth-test-a|02:ab:cd:ef:01:23|2026-09-03T10:00:00Z
EOF
cat > "$WORK/c.conf" <<EOF
ENABLED=true
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"no rotation needed"* ]]; then
    pass "policy=once + populated state → no rotation"
else
    fail "policy=once + populated state (got: $out)"
fi

# ----- 9. ROTATION_POLICY=daily, old state → rotation -----
old_ts="$(date -u -d '2 days ago' +%FT%TZ 2>/dev/null || date -u +%FT%TZ)"
cat > "$WORK/state" <<EOF
veth-test-a|02:ab:cd:ef:01:23|$old_ts
EOF
cat > "$WORK/c.conf" <<EOF
ENABLED=true
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
cat > "$WORK/state" <<EOF
veth-test-a|02:ab:cd:ef:01:23|$fresh_ts
EOF
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
if [[ "$out" == *"no rotation needed"* ]]; then
    pass "policy=daily + fresh state → no rotation"
else
    fail "policy=daily + fresh state (got: $out)"
fi

# ----- 11. Loopback skipped (no BYPASS — real filter) -----
cat > "$WORK/c.conf" <<EOF
ENABLED=true
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
# policy=connection should NOT rotate on boot trigger
# Use TARGETS= so boot iterates real ifaces; dry-run keeps them safe.
cat > "$WORK/c.conf" <<EOF
ENABLED=true
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

# ----- 13. MAC prefix check via dry-run -----
cat > "$WORK/c.conf" <<EOF
ENABLED=true
ROTATION_POLICY=once
TARGETS=veth-test-a
STATE_FILE=$WORK/state
LOG_LEVEL=info
EOF
rm -f "$WORK/state"
out="$(DEMON_MAC_CONF="$WORK/c.conf" DEMON_MAC_DRY_RUN=1 DEMON_MAC_BYPASS_PHYSICAL=1 bash "$ROOT/demon-mac.sh" connection veth-test-a 2>&1 || true)"
mac="$(grep -oP 'new_mac=\K[0-9a-f:]+' <<<"$out" | head -1 || true)"
if [[ -n "$mac" && "${mac:0:3}" == "02:" ]]; then
    pass "MAC prefix 02: (got: $mac)"
else
    fail "MAC prefix check (got: '$mac', full: $out)"
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