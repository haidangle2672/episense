# Mở cổng 1883 cho mạng LAN:
    New-NetFirewallRule -DisplayName "MQTT 1883 (LAN)" -Direction Inbound -Protocol TCP -LocalPort 1883 -Action Allow -Profile Private## Gửi tin nhắn MQTT test

    docker exec episense-mosquitto mosquitto_pub -u esp32_dev -P "MAT_KHAU" -t "iot/v1/home/sim01/telemetry" -f /mosquitto/data/sim_hot.json

    docker exec episense-mosquitto mosquitto_pub -u esp32_dev -P "MAT_KHAU" -t "iot/v1/home/dev01/cmd" -f /mosquitto/data/cmd_on.json

# Hướng dẫn chạy renew-broker-cert.ps1 (Cấp lại chứng chỉ cho server khi đổi IP)
    powershell -ExecutionPolicy Bypass -File .\tools\renew-broker-cert.ps1

# Đối chiếu với kết nối không mã hoá
    - Cổng 1883: docker run --rm -it --net container:episense-mosquitto alpine sh -c "apk add --no-cache tcpdump > /dev/null && tcpdump -i any -nn -A -s0 -c 40 'tcp port 1883'"
    - Cổng 8883: docker run --rm -it --net container:episense-mosquitto alpine sh -c "apk add --no-cache tcpdump > /dev/null && tcpdump -i any -nn -A -s0 -c 20 'tcp port 8883'"

# Xem Log của alerter (theo thời gian thực)
    docker compose logs -f --tail 50 ar# ter

    docker compose ps --services          # tìm tên service DB (vd: timesled# b, db)
    Select-String -Path .env -Pattern "POSTGRES_(USER|DB)"   # lấy user và tên database

# Sao lưu (Docker Desktop phải đang chạy và container episense-db đang lên)
    powershell -ExecutionPolicy Bypass -File .\tools\backup-db.ps1
# Thử khôi phục (không đụng tới database thật)
    powershell -ExecutionPolicy Bypass -File .\tools\restore-test.ps1

# Hướng dẫn chạy issue-vps-cert.ps1 (Cấp chứng chỉ mới cho VPS)
    .\tools\issue-vps-cert.ps1 -Ip 160.250.5.157
# Chép lên VPS bằng scp
    scp pki\vps\server.crt pki\vps\server.key episense:~/episense/mosquitto/certs/

# Xem dữ liệu gửi lên
    curl -N -s --max-time 10 http://127.0.0.1:8000/api/v1/stream

# Thử chu kỳ cảnh báo trên VPS
    - Pha 1: mở cảnh báo (ngưỡng thấp hơn nhiệt độ phòng hiện tại):
        printf 'T_HIGH=25\nT_LOW=20\n' >> .env
        docker compose up -d alerter
        docker compose logs -f --tail 30 alerter      # Ctrl+C để thoát
    - Pha 2: đóng cảnh báo (ngưỡng cao hơn nhiệt độ phòng):
        sed -i 's/^T_HIGH=.*/T_HIGH=40/; s/^T_LOW=.*/T_LOW=35/' .env
        docker compose up -d alerter
        docker compose logs -f --tail 30 alerter
    - Dọn dẹp (bắt buộc): trả về ngưỡng mặc định thật.
        sed -i '/^T_HIGH=/d; /^T_LOW=/d' .env
        docker compose up -d alerter
        docker compose logs --tail 5 alerter | grep "MQTT connected"

