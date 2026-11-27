CREATE TABLE IF NOT EXISTS app_users (
    username      text PRIMARY KEY CHECK (username = lower(username)),
    password_hash text NOT NULL,
    role          text NOT NULL DEFAULT 'viewer' CHECK (role IN ('admin', 'viewer')),
    created_at    timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON app_users TO api_ro;