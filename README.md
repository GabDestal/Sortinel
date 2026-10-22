# Sortinel

Sortinel is a Telegram bot that triages IT and security reports. Someone sends it a message describing a problem (a suspicious email, an access request, a broken laptop) and Sortinel:

1. logs a ticket (`SRT-<n>`) in a Google Sheet with status `processing`,
2. classifies the report with an AI Agent (Anthropic): category, severity, confidence and a one-line reason,
3. for phishing reports, checks every link and its host on [URLhaus](https://urlhaus.abuse.ch/),
4. replies to the user with the ticket ID and advice, updates the ticket to `open` or `to review`,
5. alerts an admin on Telegram for high-severity or unclear reports.

Users can check a ticket with `/status SRT-<n>`. If anything fails, an error workflow alerts the admin, marks the ticket `to review` and tells the user.

## Workflows

| File | Workflow | Role |
|---|---|---|
| `workflows/Sortinel Main.json` | Sortinel Main | Telegram trigger, ticket registration, AI classification, replies, alerts, `/status` |
| `workflows/Check URLs.json` | Check URLs | Sub-workflow: takes `urls` (array), queries URLhaus by URL and by host, returns a verdict |
| `workflows/Sortinel Errors.json` | Sortinel Errors | Error workflow for Sortinel Main: admin alert with ticket ID, failing node, error and execution link, ticket recovery |

Tickets live in the first sheet of a Google Sheets spreadsheet, one row per ticket:

| Column | Notes |
|---|---|
| `ticket_id` | `SRT-<execution id>`, used to find and update the row |
| `received_at`, `chat_id`, `user`, `text` | From the Telegram message |
| `category`, `severity`, `confidence`, `reason` | From the AI Agent (empty if classification failed) |
| `status` | `processing`, `open` or `to review` |
| `urlhaus_status` | URLhaus verdict for phishing reports (`known_malicious_url`, `malicious_host`, `not_listed`, `lookup_failed`, `no_urls`), empty otherwise |

## Setup: from clone to running

Requirements: Docker Desktop (or Docker Engine with Compose v2), a Telegram bot token from [@BotFather](https://t.me/BotFather), an Anthropic API key, a URLhaus Auth-Key from [abuse.ch](https://auth.abuse.ch/), a Google account with an OAuth client for the Google Sheets API, and a public HTTPS URL that forwards to port 5679 (for example `cloudflared tunnel --url http://localhost:5679` or `ngrok http 5679`). Telegram can only deliver messages to a public HTTPS webhook.

### 1. Create `.env`

```sh
cp .env.example .env
```

Fill in the values (see [Environment variables](#environment-variables)). `.env` is gitignored, so never commit it.

> If you are reusing an existing n8n volume, `N8N_ENCRYPTION_KEY` **must** be the key already stored in that volume, otherwise n8n refuses to start. Read it with
> `docker compose run --rm --entrypoint cat n8n /home/node/.n8n/config`.
> On a fresh volume, pick any long random string (for example `openssl rand -hex 32`).

### 2. Start n8n

```sh
docker compose up -d
docker compose ps        # n8n should be "running"
```

Open the editor at <http://localhost:5679>.

### 3. Create the tickets sheet

Create a Google Sheets spreadsheet (for example named `tickets`). In the first sheet, put these headers in row 1:

```
received_at | chat_id | user | text | category | severity | confidence | reason | status | urlhaus_status | ticket_id
```

### 4. Import the workflows

```sh
docker compose exec n8n n8n import:workflow --separate --input=/workflows
```

The `workflows/` folder is mounted at `/workflows` inside the container. The workflow IDs are kept, so the Execute Workflow node and the error-workflow setting still point to the right workflows.

### 5. Create the credentials (n8n UI → Credentials → Add)

| Credential | Type | Settings | Used by |
|---|---|---|---|
| Telegram | Telegram API | Access Token = bot token | Receive Report and all Telegram nodes (Main, Errors) |
| Anthropic | Anthropic | API Key | Anthropic Chat Model |
| URLhaus | Header Auth | Name = `Auth-Key`, Value = your URLhaus key | URLhaus Lookup, URLhaus Host Lookup |
| Google Sheets | Google Sheets OAuth2 API | Client ID and Secret of your Google OAuth client; add the OAuth Redirect URL shown by n8n to the client's authorized redirect URIs, then **Sign in with Google** | Register Ticket, Log Ticket, Find Ticket (Main); Find Ticket, Mark To Review (Errors) |

Open each workflow, select the credential on every node marked with a warning, and save.

### 6. Point the Google Sheets nodes to your sheet

The exported workflows don't include a spreadsheet. In **Register Ticket**, **Log Ticket** and **Find Ticket** (Sortinel Main), and **Find Ticket** and **Mark To Review** (Sortinel Errors), pick your spreadsheet under **Document** and the first sheet under **Sheet**, then save.

### 7. Publish

Publish **Check URLs** and **Sortinel Errors** first, then **Sortinel Main**. Publishing Main registers the Telegram webhook at `WEBHOOK_URL`.

The admin chat ID (`8611482415`) is set directly in Alert Admin, Alert Review and Notify Admin. Change it there if alerts should go to another chat.

## Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `N8N_ENCRYPTION_KEY` | yes | | Encrypts credentials in the n8n database. Must stay the same for the lifetime of the `n8n_data` volume. |
| `WEBHOOK_URL` | yes | | Public HTTPS base URL (with trailing `/`) that Telegram calls |
| `N8N_EDITOR_BASE_URL` | no | `http://localhost:5679/` | Base of the execution links in error alerts |

n8n's own database, workflows and credentials live in the named volume `n8n-local_n8n_data`. `docker compose down` keeps it; `docker compose down -v` deletes it. Tickets live in your Google Sheet, outside Docker.

## How to test

Send these three reports to the bot (also stored as Telegram updates in `test/telegram/`):

| Report | Expected |
|---|---|
| `I got an email from "IT Support" saying my mailbox is full. I clicked http://mailbox-quota-update.example.com/login and typed my password before I noticed the address was wrong.` | phishing · high, URLhaus check, admin alert |
| `Hi, could I get edit access to the Marketing shared drive? My manager Claire approved it this morning.` | access, status `open` |
| `something weird is going on, can someone check?` | low confidence → `to review`, review alert to admin |

Then check:

- **`/status SRT-<n>`** with an ID from a confirmation shows status, category, severity and when it was received.
- **`/status`** on its own, any other command (`/start`, `/help`...) or a message without text (sticker, photo without caption) returns the help message.
- **`/status SRT-999999`**, or an ID from another chat, returns `No ticket SRT-999999 found for this chat.`
- **Tickets sheet:** each report adds a row with its `ticket_id`, which goes from `processing` to `open` or `to review` once the run finishes.

### Run without Telegram (pinned test payload)

Receive Report has the phishing update from `test/telegram/phishing.json` pinned. In the editor, open Sortinel Main and click **Execute workflow**: the run starts from that payload instead of waiting for Telegram. Pinned data is only used in manual runs; production runs always use the real message. To try another demo, edit the pinned data on Receive Report and paste one of the other files from `test/telegram/`.

### Trigger the error workflow

Error workflows only run for production (published) executions, not for manual runs.

1. In your spreadsheet, add a tab with only `x` in cell A1. In Sortinel Main, open **Log Ticket** and switch **Sheet** to that tab (it has no `ticket_id` column to match on). Publish.
2. Send any new report to the bot.
3. Expected: the admin gets **Sortinel failed** with the ticket, failing node, error and execution link; the ticket row is set to `to review`; the user gets "pending review".
4. Set **Sheet** back to the tickets sheet and publish again.

## Reliability notes

- External calls retry 3 times: the AI Agent, URLhaus, Google Sheets, the ticket reply and the admin alerts 2000 ms apart, the Check URLs sub-workflow 1000 ms apart. The help message and the `/status` reply are sent once, without retry.
- If registering the ticket fails, the report is still classified; Log Ticket creates the row at the end.
- If the AI call still fails, the report goes to `to review` instead of failing.
- If URLhaus can't be reached, the verdict is `lookup_failed` and the user is told to treat the link as malicious.
- The AI prompt treats the report as untrusted text; links in admin alerts are defanged (`hxxp`, `[.]`).
