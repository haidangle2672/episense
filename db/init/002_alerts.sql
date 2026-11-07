CREATE TABLE IF NOT EXISTS alert_events (
    id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    time      timestamptz NOT NULL DEFAULT now(),
    device_id text        NOT NULL,
    kind      text        NOT NULL,   -- alert_open | alert_close | cmd_sent | cmd_retry | cmd_ack | cmd_failed | notify
    detail    jsonb       NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS alert_events_device_time_idx ON alert_events (device_id, time DESC);

CREATE ROLE alerter LOGIN;
GRANT CONNECT ON DATABASE episense TO alerter;
GRANT USAGE ON SCHEMA public TO alerter;
GRANT INSERT ON alert_events TO alerter;      -- chỉ được ghi thêm, không đọc/sửa/xoá