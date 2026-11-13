#!/usr/bin/env bash
# Local proof of check.sh against a fake Portal and a fake Slack. Takes about 2 minutes. No network, no secrets.
set -u
cd "$(dirname "$0")"
T="$(mktemp -d)"; export MODE_FILE="$T/mode" ALERT_LOG="$T/alerts" PORT_FILE="$T/port"
: > "$ALERT_LOG"; echo ok > "$MODE_FILE"
node testserver.js & SRV=$!
trap 'kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 50); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE")"
# Scaled timings: real window 180 s / interval 20 s / probe timeout 10 s become 12 / 2 / 2 (1/15 scale; real 60 s blip = 4 s).
export TARGET_URL="http://127.0.0.1:$PORT/api/build-id" CURL_TIMEOUT=2 RETRY_WINDOW_SECS=12 RETRY_INTERVAL_SECS=2
export STATE_FILE="$T/state" ALERT_URL_OVERRIDE="http://127.0.0.1:$PORT/alert" SLACK_WEBHOOK_URL="dummy-secret-value"
PASS=0; FAIL=0
alerts() { wc -l < "$ALERT_LOG" | tr -d ' '; }
expect() { # name, got, want
  if [ "$2" = "$3" ]; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1 (got '$2', wanted '$3')"; FAIL=$((FAIL+1)); fi
}
run() { bash ./check.sh >"$T/out" 2>&1; echo $?; }
reset() { : > "$ALERT_LOG"; rm -f "$STATE_FILE"; }

echo "-- healthy"; reset; echo ok > "$MODE_FILE"
expect "healthy: exit 0" "$(run)" 0
expect "healthy: no alert" "$(alerts)" 0

echo "-- blip that recovers inside the window (4 s, scaled 60 s)"; reset; echo 503 > "$MODE_FILE"
( sleep 4; echo ok > "$MODE_FILE" ) & BL=$!
expect "blip: exit 0" "$(run)" 0; wait $BL
expect "blip: no alert" "$(alerts)" 0
expect "blip: no state left" "$([ -e "$STATE_FILE" ] && echo yes || echo no)" no

echo "-- down past the window (503 Application starting)"; reset; echo 503 > "$MODE_FILE"
expect "down: exit 0" "$(run)" 0
expect "down: exactly one DOWN alert" "$(alerts)" 1
grep -q 'Portal is DOWN. proposals.pickletile.com has not answered since .* CT (.* checks). Last answer: 503 Application starting.' "$ALERT_LOG" \
  && expect "down: text matches" ok ok || { expect "down: text matches" "$(cat "$ALERT_LOG")" "expected text"; }
echo "   sent: $(cat "$ALERT_LOG")"
echo "-- still down on the next run, inside 30 minutes"
expect "next run: exit 0" "$(run)" 0
expect "next run: no second alert" "$(alerts)" 1
echo "-- still down after the repeat interval (scaled to 3 s)"
sleep 3; REPEAT_SECS=3 expect "repeat: exit 0" "$(REPEAT_SECS=3 run)" 0
expect "repeat: one reminder (2 alerts total)" "$(alerts)" 2
echo "   sent: $(tail -1 "$ALERT_LOG")"
echo "-- recovery"; echo ok > "$MODE_FILE"; sleep 2
expect "recovery: exit 0" "$(run)" 0
expect "recovery: exactly one BACK UP (3 alerts total)" "$(alerts)" 3
grep -q 'Portal is back up at .* CT. It was down' "$ALERT_LOG" && expect "recovery: text" ok ok || expect "recovery: text" "$(tail -1 "$ALERT_LOG")" "back up text"
echo "   sent: $(tail -1 "$ALERT_LOG")"
echo "-- recovery after a real-length outage (state says it began 19 minutes ago)"; reset
echo "since=$(( $(date +%s) - 1140 )) last=$(( $(date +%s) - 60 ))" > "$STATE_FILE"
expect "19 min: exit 0" "$(run)" 0
grep -q 'It was down about 19 minutes\.' "$ALERT_LOG" && expect "19 min: text says about 19 minutes" ok ok || expect "19 min: text says about 19 minutes" "$(cat "$ALERT_LOG")" "about 19 minutes"
echo "   sent: $(cat "$ALERT_LOG")"
echo "   (below, counts restart from the reset above)"
reset; : > "$ALERT_LOG"
expect "recovery: state cleared" "$([ -e "$STATE_FILE" ] && echo yes || echo no)" no
run >/dev/null; expect "after recovery, next healthy run sends nothing" "$(alerts)" 0

echo "-- 200 without buildId counts as down"; reset; echo nobuild > "$MODE_FILE"
run >/dev/null; expect "no buildId: one DOWN alert" "$(alerts)" 1
echo "   sent: $(cat "$ALERT_LOG")"
echo "-- hang counts as down"; reset; echo hang > "$MODE_FILE"
run >/dev/null; expect "hang: one DOWN alert" "$(alerts)" 1
echo "   sent: $(cat "$ALERT_LOG")"
echo ok > "$MODE_FILE"; reset

echo "-- missing secret"; unset SLACK_WEBHOOK_URL
( unset ALERT_URL_OVERRIDE SLACK_BOT_TOKEN SLACK_USER_ID; bash ./check.sh >"$T/out" 2>&1; echo $? >"$T/rc" )
expect "missing secret: non-zero exit" "$([ "$(cat "$T/rc")" != 0 ] && echo nonzero)" nonzero
expect "missing secret: nothing URL-like printed" "$(grep -cE 'https?://' "$T/out")" 0
echo "   printed: $(cat "$T/out")"

echo "-- Slack post failing (and the secret never printed)"; reset; export ALERT_URL_OVERRIDE="http://127.0.0.1:$PORT/alert"; echo 503 > "$MODE_FILE"
export SLACK_WEBHOOK_URL="https://example.invalid/services/T0/B0/SECRETXYZ"
ALERT_URL_OVERRIDE="http://127.0.0.1:$PORT/alertfail" bash ./check.sh >"$T/out" 2>&1; rc=$?
expect "slack failing: non-zero exit" "$([ $rc != 0 ] && echo nonzero)" nonzero
expect "slack failing: secret not printed" "$(grep -c SECRETXYZ "$T/out")" 0
expect "slack failing: no state saved (retries next run)" "$([ -e "$STATE_FILE" ] && echo yes || echo no)" no
echo "   printed: $(cat "$T/out")"

echo "-- test_alert input"; reset; export SLACK_WEBHOOK_URL=dummy-secret-value ALERT_URL_OVERRIDE="http://127.0.0.1:$PORT/alert"
TEST_ALERT=true bash ./check.sh >/dev/null 2>&1
expect "test alert: one message" "$(alerts)" 1

echo "-- issue backend through a fake gh (create, no second create, close)"
mkdir -p "$T/bin"; cat > "$T/bin/gh" <<'GH'
#!/usr/bin/env bash
D="$GH_FAKE_DIR"; echo "$*" >> "$D/calls"
case "$1 $2" in
  "issue list") [ -f "$D/body" ] && echo 7 ;;
  "issue view") cat "$D/body" ;;
  "issue create") while [ $# -gt 0 ]; do [ "$1" = "--body" ] && echo "$2" > "$D/body"; shift; done ;;
  "issue edit") while [ $# -gt 0 ]; do [ "$1" = "--body" ] && echo "$2" > "$D/body"; shift; done ;;
  "issue close") rm -f "$D/body" ;;
esac; exit 0
GH
chmod +x "$T/bin/gh"; export GH_FAKE_DIR="$T"; : > "$T/calls"; reset; unset STATE_FILE
echo 503 > "$MODE_FILE"; export PATH="$T/bin:$PATH"; run >/dev/null; run >/dev/null; sed "s/^/   run output: /" "$T/out"
expect "issue: exactly one create, DOWN alert once" "$(grep -c 'issue create' "$T/calls")/$(alerts)" 1/1
echo ok > "$MODE_FILE"; run >/dev/null
expect "issue: closed on recovery, BACK UP sent" "$(grep -c 'issue close' "$T/calls")/$(alerts)" 1/2
echo "   (fake gh only: the real GitHub issue calls are not exercised locally)"

echo; echo "RESULT: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
