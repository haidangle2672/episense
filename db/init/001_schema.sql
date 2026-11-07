CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE IF NOT EXISTS telemetry (
    time        timestamptz NOT NULL,          -- thời điểm đo (từ ESP32, UTC)
    site        text        NOT NULL,
    device_id   text        NOT NULL,
    temp_c      real,
    hum_pct     real,
    seq         bigint,
    received_at timestamptz NOT NULL DEFAULT now(),  -- thời điểm server nhận
    PRIMARY KEY (device_id, time)              -- chống trùng; chứa cột time như Timescale yêu cầu
);

-- Biến bảng thường thành hypertable, tự chia chunk theo thời gian
SELECT create_hypertable('telemetry', 'time', if_not_exists => TRUE);

-- Retention: tự xoá dữ liệu thô cũ hơn 90 ngày (điều chỉnh theo nhu cầu)
SELECT add_retention_policy('telemetry', INTERVAL '90 days', if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS device_status (
    device_id   text PRIMARY KEY,
    site        text        NOT NULL,
    state       text        NOT NULL CHECK (state IN ('online', 'offline')),
    updated_at  timestamptz NOT NULL DEFAULT now()
);