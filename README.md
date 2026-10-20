# Sortinel

Sortinel is a Telegram bot that triages IT and security reports. Someone sends it a message describing a problem (a suspicious email, an access request, a broken laptop) and Sortinel:

1. logs a ticket (`SRT-<n>`) in Postgres with status `processing`,
2. classifies the report with an AI Agent (Anthropic): category, severity, confidence and a one-line reason,
3. for phishing reports, checks every link and its host on [URLhaus](https://urlhaus.abuse.ch/),
4. replies to the user with the ticket ID and advice, updates the ticket to `open` or `to review`,
5. alerts an admin on Telegram for high-severity or unclear reports.

Users can check a ticket with `/status SRT-<n>`. If anything fails, an error workflow alerts the admin, marks the ticket `to review` and tells the user.

![Overview of Sortinel Main](docs/screenshots/main-workflow.png)
<!-- TODO screenshot: full Sortinel Main canvas -->

## Workflows

| File | Workflow | Role |
|---|---|---|
| `workflows/Sortinel Main.json` | Sortinel Main | Telegram trigger, dedupe, ticket registration, AI classification, replies, alerts, `/status` |
| `workflows/Check URLs.json` | Check URLs | Sub-workflow: takes `urls` (array), queries URLhaus by URL and by host, returns a verdict |
| `workflows/Sortinel Errors.json` | Sortinel Errors | Error workflow for Sortinel Main: admin alert with workflow name and execution link, ticket recovery |

Tickets live in the `tickets` table created by `db/init/01-tickets.sql`:

| Column | Notes |
|---|---|
| `ticket_id` | `SRT-<execution id>`, unique |
| `received_at`, `chat_id`, `message_id`, `user`, `text` | From the Telegram message |
| `category`, `severity`, `confidence`, `reason` | From the AI Agent (empty if classification failed) |
| `status` | `processing`, `open` or `to review` |
| `urlhaus_status` | `not_checked` unless the report went through Check URLs |

## Setup: from clone to running

Requirements: Docker Desktop (or Docker Engine with Compose v2), a Telegram bot token from [@BotFather](https://t.me/BotFather), an Anthropic API key, a URLhaus Auth-Key from [abuse.ch](https://auth.abuse.ch/), and a public HTTPS URL that forwards to port 5679 (for example `cloudflared tunnel --url http://localhost:5679` or `ngrok http 5679`). Telegram can only deliver messages to a public HTTPS webhook.

### 1. Create `.env`

```sh
cp .env.example .env
```

Fill in the values (see [Environment variables](#environment-variables)). `.env` is gitignored, so never commit it.

> If you are reusing an existing n8n volume, `N8N_ENCRYPTION_KEY` **must** be the key already stored in that volume, otherwise n8n refuses to start. Read it with
> `docker compose run --rm --no-deps --entrypoint cat n8n /home/node/.n8n/config`.
> On a fresh volume, pick any long random string (for example `openssl rand -hex 32`).

### 2. Start the stack

```sh
docker compose up -d
docker compose ps        # postgres should be "healthy", n8n "running"
```

The Postgres container creates the `tickets` table on its first start. n8n waits for Postgres to be healthy. Open the editor at <http://localhost:5679>.

### 3. Import the workflows

```sh
docker compose exec n8n n8n import:workflow --separate --input=/workflows
```

The `workflows/` folder is mounted at `/workflows` inside the container. The workflow IDs are kept, so the Execute Workflow node and the error-workflow setting still point to the right workflows.

### 4. Create the credentials (n8n UI → Credentials → Add)

| Credential | Type | Settings | Used by |
|---|---|---|---|
| Telegram | Telegram API | Access Token = bot token | Receive Report and all Telegram nodes (Main, Errors) |
| Anthropic | Anthropic | API Key | Anthropic Chat Model |
| URLhaus | Header Auth | Name = `Auth-Key`, Value = your URLhaus key | URLhaus Lookup, URLhaus Host Lookup |
| Postgres | Postgres | Host = `postgres` (the compose service name), Database = `sortinel`, User = `sortinel`, Password = `POSTGRES_PASSWORD`, Port = `5432`, SSL = disable | Find Duplicate, Register Ticket, Log Ticket, Find Ticket (Main); Find Ticket, Mark To Review (Errors) |

Open each workflow, select the credential on every node marked with a warning, and save.

![Credentials list](docs/screenshots/credentials.png)
<!-- TODO screenshot: Credentials page with the four credentials -->

### 5. Publish

Publish **Check URLs** and **Sortinel Errors** first, then **Sortinel Main**. Publishing Main registers the Telegram webhook at `WEBHOOK_URL`.

The admin chat ID (`8611482415`) is set directly in Alert Admin, Alert Review and Notify Admin. Change it there if alerts should go to another chat.

## Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `N8N_ENCRYPTION_KEY` | yes | | Encrypts credentials in the n8n database. Must stay the same for the lifetime of the `n8n_data` volume. |
| `WEBHOOK_URL` | yes | | Public HTTPS base URL (with trailing `/`) that Telegram calls |
| `N8N_EDITOR_BASE_URL` | no | `http://localhost:5679/` | Base of the execution links in error alerts |
| `POSTGRES_DB` | no | `sortinel` | Database holding `tickets` |
| `POSTGRES_USER` | no | `sortinel` | Postgres user |
| `POSTGRES_PASSWORD` | yes | | Postgres password. It is only applied when the volume is first created; to change it later run `docker compose exec postgres psql -U sortinel -c "ALTER USER sortinel PASSWORD '...'"`. |

Data lives in two named volumes: `n8n-local_n8n_data` (n8n's own database, workflows and credentials) and `n8n-local_postgres_data` (tickets). `docker compose down` keeps them; `docker compose down -v` deletes them.

## How to test

Send these three reports to the bot (also stored as Telegram updates in `test/telegram/`):

| Report | Expected |
|---|---|
| `I got an email from "IT Support" saying my mailbox is full. I clicked http://mailbox-quota-update.example.com/login and typed my password before I noticed the address was wrong.` | phishing · high, URLhaus check, admin alert |
| `Hi, could I get edit access to the Marketing shared drive? My manager Claire approved it this morning.` | access, status `open` |
| `something weird is going on, can someone check?` | low confidence → `to review`, review alert to admin |

![Phishing report reply](docs/screenshots/demo-phishing.png)
<!-- TODO screenshot: Telegram chat with the three replies -->

Then check:

- **Duplicate:** send the access report again. The bot replies `Already logged as SRT-<n>` and no new row is added.
- **`/status SRT-<n>`** with an ID from a confirmation shows status, category and severity.
- **`/status`**, `/status 42` or `/status abc` returns the usage message.
- **`/status SRT-999999`**, or an ID from another chat, returns `Ticket not found.`
- **Tickets table:** `docker compose exec postgres psql -U sortinel -c "SELECT ticket_id, category, severity, status, urlhaus_status FROM tickets ORDER BY received_at DESC;"`

![Tickets table](docs/screenshots/tickets-table.png)
<!-- TODO screenshot: psql output or DB viewer -->

### Run without Telegram (pinned test payload)

Receive Report has the phishing update from `test/telegram/phishing.json` pinned. In the editor, open Sortinel Main and click **Execute workflow**: the run starts from that payload instead of waiting for Telegram. Pinned data is only used in manual runs; production runs always use the real message. To try another demo, edit the pinned data on Receive Report and paste one of the other files from `test/telegram/`.

### Trigger the error workflow

Error workflows only run for production (published) executions, not for manual runs.

1. In Sortinel Main, open **Log Ticket** and change `tickets` to `tickets_missing` in the query. Publish.
2. Send any new report to the bot.
3. Expected: the admin gets **Sortinel failed** with the workflow name, failing node, error and execution link; the ticket is set to `to review`; the user gets "pending review".
4. Change the query back to `tickets` and publish again.

Quicker variant (admin alert only, no ticket is created): `docker compose stop postgres`, send a report, then `docker compose start postgres`.

![Error alert](docs/screenshots/error-alert.png)
<!-- TODO screenshot: "Sortinel failed" Telegram alert -->

## Reliability notes

- Every external call (AI Agent, HTTP, Postgres, Telegram, sub-workflow) retries 3 times, 2000 ms apart.
- If the AI call still fails, the report goes to `to review` instead of failing.
- If URLhaus can't be reached, the verdict is `lookup_failed` and the user is told to treat the link as malicious.
- The AI prompt treats the report as untrusted text; links in admin alerts are defanged (`hxxp`, `[.]`).
