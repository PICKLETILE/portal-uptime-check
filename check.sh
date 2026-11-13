#!/usr/bin/env bash
# Outside uptime check for the PICKLETILE Portal. Runs from GitHub Actions every 5 minutes (or by hand).
# UP = HTTP 200 and the body contains "buildId". A failure is retried every 20 s for up to 3 minutes inside
# the same run, because a normal publish restart answers 503 for 90 to 150 s and must not page anyone.
# State (one "PORTAL DOWN" issue) means one DOWN message, one BACK UP message, a reminder at most every 30 minutes.
# Never use set -x here: the Slack secrets are in the environment.
set -uo pipefail

TARGET_URL="${TARGET_URL:-https://proposals.pickletile.com/api/build-id}"
CURL_TIMEOUT="${CURL_TIMEOUT:-10}"
RETRY_WINDOW_SECS="${RETRY_WINDOW_SECS:-180}"      # tests only: scaled down
RETRY_INTERVAL_SECS="${RETRY_INTERVAL_SECS:-20}"   # tests only: scaled down
REPEAT_SECS="${REPEAT_SECS:-1800}"                 # tests only: scaled down
STATE_FILE="${STATE_FILE:-}"                       # tests only: file instead of the GitHub issue
ALERT_URL_OVERRIDE="${ALERT_URL_OVERRIDE:-}"       # tests only: send alerts here instead of Slack
TEST_ALERT="${TEST_ALERT:-false}"
ISSUE_TITLE="PORTAL DOWN"

fail() { echo "ERROR: $*" >&2; exit 1; }

# Hide secrets from the Actions log even if something prints them by accident.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  for v in SLACK_WEBHOOK_URL SLACK_BOT_TOKEN SLACK_USER_ID; do
    [ -n "${!v:-}" ] && echo "::add-mask::${!v}"
  done
fi

# --- secrets: fail loudly, before anything else, so a missing secret is seen at once ---
if [ -z "${SLACK_WEBHOOK_URL:-}" ] && { [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_USER_ID:-}" ]; }; then
  fail "no Slack destination configured. Add the repository secret SLACK_WEBHOOK_URL (preferred), or both SLACK_BOT_TOKEN and SLACK_USER_ID. See README.md."
fi

# --- time helpers (America/Chicago; GNU date or BSD date) ---
fmt_time() { # epoch -> "4:41 pm"
  local out
  out="$(TZ=America/Chicago date -d "@$1" '+%-I:%M %p' 2>/dev/null || TZ=America/Chicago date -r "$1" '+%-I:%M %p')"
  echo "$out" | tr 'AMP' 'amp'
}
fmt_dur() { # seconds -> "about 19 minutes"
  local s=$1 m
  m=$(( (s + 30) / 60 ))
  if [ "$m" -lt 1 ]; then echo "under a minute"
  elif [ "$m" -eq 1 ]; then echo "about 1 minute"
  elif [ "$m" -lt 60 ]; then echo "about $m minutes"
  else echo "about $((m / 60)) hr $((m % 60)) min"; fi
}

# --- sending the direct message ---
post_json() { # $1 url, $2 json, $3 optional bearer; prints body; returns 0 on HTTP 200
  local code
  code="$(curl -sS -o /tmp/portal-check-resp.$$ -w '%{http_code}' --max-time 15 \
        -H 'Content-type: application/json; charset=utf-8' ${3:+-H "Authorization: Bearer $3"} \
        --data "$2" "$1" 2>/dev/null)" || { echo "curl failed" >&2; rm -f /tmp/portal-check-resp.$$; return 1; }
  cat /tmp/portal-check-resp.$$ 2>/dev/null; rm -f /tmp/portal-check-resp.$$
  [ "$code" = "200" ]
}
send_dm() { # $1 message text (plain, no quotes/backslashes)
  local text="$1" json body ch
  json="{\"text\":\"$text\"}"
  if [ -n "$ALERT_URL_OVERRIDE" ]; then
    post_json "$ALERT_URL_OVERRIDE" "$json" >/dev/null || fail "alert post failed (override endpoint)"
  elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    post_json "$SLACK_WEBHOOK_URL" "$json" >/dev/null || fail "Slack webhook post failed. Check the SLACK_WEBHOOK_URL secret."
  else
    body="$(post_json "https://slack.com/api/conversations.open" "{\"users\":\"$SLACK_USER_ID\"}" "$SLACK_BOT_TOKEN")" || fail "Slack conversations.open failed"
    echo "$body" | grep -q '"ok":[ ]*true' || fail "Slack conversations.open refused (check scopes im:write)"
    ch="$(echo "$body" | sed -n 's/.*"channel":{"id":"\([A-Z0-9]*\)".*/\1/p')"
    [ -n "$ch" ] || fail "Slack conversations.open returned no channel"
    body="$(post_json "https://slack.com/api/chat.postMessage" "{\"channel\":\"$ch\",\"text\":\"$text\"}" "$SLACK_BOT_TOKEN")" || fail "Slack chat.postMessage failed"
    echo "$body" | grep -q '"ok":[ ]*true' || fail "Slack chat.postMessage refused (check scope chat:write)"
  fi
  echo "alert sent: $text"
}

if [ "$TEST_ALERT" = "true" ]; then
  send_dm "Test: the Portal alarm is connected. If you can read this, a real outage will reach you here."
  exit 0
fi

# --- state: since=<epoch> last=<epoch>. Backend 1: a file (tests). Backend 2: one open issue titled PORTAL DOWN. ---
ISSUE_NO=""
SINCE=""; LAST=""
state_read() { # sets SINCE and LAST (and ISSUE_NO); empty when no alert is open
  local raw="" parsed
  if [ -n "$STATE_FILE" ]; then
    [ -f "$STATE_FILE" ] || return 0
    raw="$(cat "$STATE_FILE")"
  else
    ISSUE_NO="$(gh issue list --state open --search "\"$ISSUE_TITLE\" in:title" --json number,title --jq "[.[]|select(.title==\"$ISSUE_TITLE\")][0].number // empty")" || fail "could not read state (gh issue list)"
    [ -n "$ISSUE_NO" ] || return 0
    raw="$(gh issue view "$ISSUE_NO" --json body --jq .body)" || fail "could not read state (gh issue view)"
  fi
  parsed="$(echo "$raw" | sed -n 's/.*since=\([0-9]*\).*last=\([0-9]*\).*/\1 \2/p' | head -1)"
  [ -n "$parsed" ] && read -r SINCE LAST <<< "$parsed"
  return 0
}
state_write() { # $1 since, $2 last
  local body="since=$1 last=$2"
  if [ -n "$STATE_FILE" ]; then echo "$body" > "$STATE_FILE"; return; fi
  if [ -n "$ISSUE_NO" ]; then gh issue edit "$ISSUE_NO" --body "$body" >/dev/null || fail "could not update state"
  else gh issue create --title "$ISSUE_TITLE" --body "$body" >/dev/null || fail "could not create state issue"; fi
}
state_clear() { # $1 comment
  if [ -n "$STATE_FILE" ]; then rm -f "$STATE_FILE"; return; fi
  [ -n "$ISSUE_NO" ] && { gh issue close "$ISSUE_NO" --comment "$1" >/dev/null || fail "could not close state issue"; }
}

# --- one probe: sets PROBE_OK (1/0) and PROBE_DETAIL ("503 Application starting" / "no answer (timed out)") ---
probe() {
  local code rc
  rm -f /tmp/portal-check-body.$$
  code="$(curl -sS -o /tmp/portal-check-body.$$ -w '%{http_code}' --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" "$TARGET_URL" 2>/dev/null)"; rc=$?
  PROBE_OK=0
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 28 ]; then PROBE_DETAIL="no answer (timed out)"; else PROBE_DETAIL="no answer (connection failed)"; fi
  elif [ "$code" = "200" ] && grep -q '"buildId"' /tmp/portal-check-body.$$; then
    PROBE_OK=1; PROBE_DETAIL="200 OK"
  else
    local snippet
    snippet="$(head -c 200 /tmp/portal-check-body.$$ 2>/dev/null | sed 's/<[^>]*>/ /g' | tr -cd 'A-Za-z0-9 .,:;!_-' | cut -c1-40)"
    PROBE_DETAIL="$code${snippet:+ $snippet}"
  fi
  rm -f /tmp/portal-check-body.$$
}

state_read

probe
if [ "$PROBE_OK" = 1 ]; then
  if [ -n "$SINCE" ]; then
    send_dm "Portal is back up at $(fmt_time "$(date +%s)") CT. It was down $(fmt_dur $(( $(date +%s) - SINCE )))."
    state_clear "Back up at $(fmt_time "$(date +%s)") CT."
  else
    echo "Portal is up."
  fi
  exit 0
fi

# Failing. If an alert is already open, do not wait out another 3 minutes: one more probe is enough.
FIRST_FAIL="$(date +%s)"; CHECKS=1
if [ -z "$SINCE" ]; then
  END=$(( FIRST_FAIL + RETRY_WINDOW_SECS ))
  while [ "$(date +%s)" -lt "$END" ]; do
    sleep "$RETRY_INTERVAL_SECS"
    probe; CHECKS=$((CHECKS + 1))
    if [ "$PROBE_OK" = 1 ]; then
      echo "Portal answered again after $CHECKS checks (inside the restart window); no alert."
      exit 0
    fi
  done
  send_dm "Portal is DOWN. proposals.pickletile.com has not answered since $(fmt_time "$FIRST_FAIL") CT ($CHECKS checks). Last answer: $PROBE_DETAIL."
  state_write "$FIRST_FAIL" "$(date +%s)"
  exit 0
fi

NOW="$(date +%s)"
if [ $(( NOW - LAST )) -ge "$REPEAT_SECS" ]; then
  send_dm "Portal is still DOWN. proposals.pickletile.com has not answered since $(fmt_time "$SINCE") CT ($(fmt_dur $(( NOW - SINCE )))). Last answer: $PROBE_DETAIL."
  state_write "$SINCE" "$NOW"
else
  echo "Still down since $(fmt_time "$SINCE") CT; next reminder not due yet."
fi
exit 0
