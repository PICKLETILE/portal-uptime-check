# Portal uptime check

Every 5 minutes GitHub asks `https://proposals.pickletile.com/api/build-id` whether the Portal answers. That page does no database work and writes nothing. If the Portal has not answered for 3 minutes in a row, it sends one direct message in Slack. When it answers again, it sends one "back up" message. A normal publish restart (90 to 150 seconds of "Application starting") never sends anything.

The three files: `.github/workflows/portal-uptime.yml` (the schedule), `check.sh` (the check), `test.sh` with `testserver.js` (local proof; not needed to run it).

What it sends (times in Central):
- `Portal is DOWN. proposals.pickletile.com has not answered since 4:41 pm CT (3 checks). Last answer: 503 Application starting.`
- Every 30 minutes while still down: `Portal is still DOWN. ... since 4:41 pm CT (about 30 minutes). ...`
- `Portal is back up at 5:00 pm CT. It was down about 19 minutes.`

It remembers "an alert is open" with one GitHub issue titled `PORTAL DOWN` (opened when it alerts, closed when the Portal is back). It needs no database and only the built-in `GITHUB_TOKEN` with `issues: write`.

## Setup (done once by the repository owner; the Slack secret is created and saved by the owner only)

1. Open https://api.slack.com/apps and click Create New App, From scratch, name it "Portal alarm", pick the PICKLETILE workspace.
2. In the app, open Incoming Webhooks, switch it On, click "Add New Webhook to Workspace", and choose yourself (a person, not a channel) as the place it posts. If the picker offers only channels, use the bot-token route below instead.
3. Copy the Webhook URL (it starts `https://hooks.slack.com/services/`). Treat it like a password.
4. Open the repository on GitHub, Settings, Secrets and variables, Actions, New repository secret.
5. Name `SLACK_WEBHOOK_URL`, paste the URL as the value, click Add secret.
6. Open the repository's Actions tab, click "Portal uptime", Run workflow, tick `test_alert`, click Run workflow.
7. Check that a test message arrives in Slack as a direct message from "Portal alarm". If it does, switch the workflow on (Actions tab, Portal uptime, Enable workflow) and the 5-minute schedule starts.

Bot-token route (only if step 2 cannot target a person): in the app, OAuth & Permissions, add the bot scopes `chat:write` and `im:write`, install to the workspace, copy the Bot User OAuth Token; in Slack open your profile, More, Copy member ID. Add two secrets in step 5: `SLACK_BOT_TOKEN` and `SLACK_USER_ID`. The check then calls `conversations.open` and `chat.postMessage`.

## Things to know
- If the secret is missing the job fails red on purpose, and GitHub emails the repository owner. The workflow stays switched off on the Actions tab until the secret has been added. A failed Slack post also fails the job, so GitHub's own failure email is the backstop.
- GitHub may start a scheduled run a few minutes late, and the shortest interval it allows is 5 minutes.
- In a public repository GitHub switches scheduled workflows off after 60 days with no repository activity. Any commit, or re-enabling it on the Actions tab, turns it back on.
- A run that waits out a restart takes up to about 4 minutes; GitHub bills each job in whole minutes (matters only in a private repository).
- Run it by hand: `SLACK_WEBHOOK_URL=... STATE_FILE=/tmp/s bash check.sh`. `bash test.sh` runs the local proof (about 2 minutes, no network).
