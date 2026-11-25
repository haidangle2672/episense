#!/bin/bash
# db/init/003_roles.sh: tạo/đặt mật khẩu cho các role ứng dụng.
# Chạy tự động 1 lần khi volume DB còn trống, sau 001 và 002 (theo thứ tự tên file).
# (không cần "set -e": entrypoint của image đã bật sẵn, và ON_ERROR_STOP lo phần SQL)

psql -v ON_ERROR_STOP=1 \
     -v alerter_pw="$ALERTER_DB_PASSWORD" \
     -v grafana_pw="$GRAFANA_DB_PASSWORD" \
     -v api_pw="$API_DB_PASS" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'

-- alerter: role đã tạo ở 002_alerts.sql nhưng chưa có mật khẩu
ALTER ROLE alerter PASSWORD :'alerter_pw';

-- grafana_ro: chỉ đọc cho dashboard
CREATE ROLE grafana_ro LOGIN PASSWORD :'grafana_pw';
GRANT CONNECT ON DATABASE episense TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
GRANT SELECT ON telemetry, device_status, alert_events TO grafana_ro;
ALTER ROLE grafana_ro SET statement_timeout = '30s';

-- api_ro: chỉ đọc cho REST API, có giới hạn kết nối và thời gian truy vấn
CREATE ROLE api_ro LOGIN PASSWORD :'api_pw' CONNECTION LIMIT 10;
GRANT CONNECT ON DATABASE episense TO api_ro;
GRANT USAGE ON SCHEMA public TO api_ro;
GRANT SELECT ON telemetry, device_status, alert_events TO api_ro;
ALTER ROLE api_ro SET statement_timeout = '5s';
SQL