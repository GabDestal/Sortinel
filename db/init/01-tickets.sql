-- Runs once, when the postgres_data volume is first created.
CREATE TABLE IF NOT EXISTS tickets (
    ticket_id       text        NOT NULL UNIQUE,
    received_at     timestamptz NOT NULL DEFAULT now(),
    chat_id         bigint      NOT NULL,
    message_id      bigint,
    "user"          text,
    text            text        NOT NULL,
    category        text        CHECK (category IN ('phishing', 'access', 'device', 'other')),
    severity        text        CHECK (severity IN ('low', 'medium', 'high')),
    confidence      numeric(3, 2) CHECK (confidence BETWEEN 0 AND 1),
    reason          text,
    status          text        NOT NULL DEFAULT 'processing'
                                CHECK (status IN ('processing', 'open', 'to review')),
    urlhaus_status  text        NOT NULL DEFAULT 'not_checked',
    CONSTRAINT ticket_id_format CHECK (ticket_id ~ '^SRT-[0-9]+$')
);

-- Duplicate check in Sortinel Main looks up (chat_id, text)
CREATE INDEX IF NOT EXISTS tickets_chat_text_idx ON tickets (chat_id, md5(text));
