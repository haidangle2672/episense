import json
import logging
import os
import re
import signal
import threading
import time
import uuid

import paho.mqtt.client as mqtt
import psycopg
from psycopg.types.json import Jsonb

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("alerter")

MQTT_HOST = os.environ.get("MQTT_HOST", "mosquitto")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_USER = os.environ["MQTT_USER"]
MQTT_PASS = os.environ["MQTT_PASS"]

DB_KW = dict(
    host=os.environ.get("POSTGRES_HOST", "db"),
    dbname=os.environ["POSTGRES_DB"],
    user=os.environ["POSTGRES_USER"],
    password=os.environ["POSTGRES_PASSWORD"],
    connect_timeout=5,
)

T_HIGH = float(os.environ.get("T_HIGH", "35.0"))
T_LOW = float(os.environ.get("T_LOW", "33.0"))
CONFIRM_N = int(os.environ.get("CONFIRM_N", "3"))
COOLDOWN_S = int(os.environ.get("COOLDOWN_S", "300"))
ACK_TIMEOUT_S = int(os.environ.get("ACK_TIMEOUT_S", "10"))
MAX_RETRIES = int(os.environ.get("MAX_RETRIES", "2"))
CMD_TTL_S = 30

if T_LOW >= T_HIGH:
    raise SystemExit("T_LOW phải nhỏ hơn T_HIGH (cần hysteresis)")

TOPIC_RE = re.compile(r"^iot/v1/([\w-]+)/([\w-]+)/(telemetry|ack)$")


class Db:
    def __init__(self):
        self.conn = None

    def execute(self, sql, params):
        for _ in range(2):
            try:
                if self.conn is None or self.conn.closed:
                    self.conn = psycopg.connect(autocommit=True, **DB_KW)
                self.conn.execute(sql, params)
                return True
            except psycopg.OperationalError as e:
                log.warning("DB error: %s", e)
                self.conn = None
                time.sleep(1)
        return False


db = Db()
lock = threading.Lock()   # callback MQTT và vòng lặp timeout chạy ở 2 thread khác nhau


class DevState:
    def __init__(self):
        self.alert = False        # đang trong trạng thái cảnh báo
        self.hi = 0               # số mẫu liên tiếp >= T_HIGH
        self.lo = 0               # số mẫu liên tiếp <= T_LOW
        self.last_notify = 0.0    # thời điểm thông báo gần nhất (cooldown)
        self.notified = False     # alert hiện tại đã được thông báo chưa


devices = {}   # (site, device_id) -> DevState
pending = {}   # (site, device_id) -> lệnh đang chờ ACK


def audit(device_id, kind, detail=None):
    db.execute(
        "INSERT INTO alert_events (device_id, kind, detail) VALUES (%s, %s, %s)",
        (device_id, kind, Jsonb(detail or {})),
    )


def notify(device_id, text):
    # Giai đoạn học: ghi log + nhật ký. Sau này thay bằng Telegram/email/webhook.
    log.warning("NOTIFY [%s] %s", device_id, text)
    audit(device_id, "notify", {"text": text})


def issue_cmd(client, key, value, cmd_id=None, retries=0):
    site, device_id = key
    cmd_id = cmd_id or uuid.uuid4().hex
    payload = {"v": 1, "cmd_id": cmd_id, "ts": int(time.time()),
               "action": "fan", "value": value, "ttl_s": CMD_TTL_S}
    client.publish(f"iot/v1/{site}/{device_id}/cmd", json.dumps(payload), qos=1)
    # Mỗi thiết bị chỉ giữ 1 lệnh chờ: lệnh mới thay lệnh cũ
    pending[key] = {"cmd_id": cmd_id, "value": value, "sent_at": time.time(), "retries": retries}
    audit(device_id, "cmd_retry" if retries else "cmd_sent", {"cmd_id": cmd_id, "value": value, "retries": retries})


def open_alert(client, key, temp):
    site, device_id = key
    st = devices[key]
    log.warning("ALERT OPEN %s temp=%.1f", device_id, temp)
    audit(device_id, "alert_open", {"temp_c": temp, "t_high": T_HIGH})
    issue_cmd(client, key, "on")
    if time.time() - st.last_notify >= COOLDOWN_S:
        st.last_notify = time.time()
        st.notified = True
        notify(device_id, f"Nhiệt độ cao {temp:.1f} °C (ngưỡng {T_HIGH} °C), đã gửi lệnh bật quạt")
    else:
        st.notified = False
        log.info("notify suppressed by cooldown for %s", device_id)


def close_alert(client, key, temp):
    site, device_id = key
    st = devices[key]
    log.warning("ALERT CLOSE %s temp=%.1f", device_id, temp)
    audit(device_id, "alert_close", {"temp_c": temp, "t_low": T_LOW})
    issue_cmd(client, key, "off")
    if st.notified:
        notify(device_id, f"Nhiệt độ đã về {temp:.1f} °C (≤ {T_LOW} °C), tắt quạt")


def process_telemetry(client, key, data):
    if data.get("v") != 1:
        return
    temp = float(data["temp_c"])
    if not (-40 <= temp <= 80):
        return
    with lock:
        st = devices.setdefault(key, DevState())
        if not st.alert:
            st.hi = st.hi + 1 if temp >= T_HIGH else 0
            if st.hi >= CONFIRM_N:
                st.alert, st.hi, st.lo = True, 0, 0
                open_alert(client, key, temp)
        else:
            st.lo = st.lo + 1 if temp <= T_LOW else 0
            if st.lo >= CONFIRM_N:
                st.alert, st.hi, st.lo = False, 0, 0
                close_alert(client, key, temp)
        # Vùng T_LOW < temp < T_HIGH: không đổi trạng thái (hysteresis)


def process_ack(key, data):
    device_id = key[1]
    with lock:
        p = pending.get(key)
        if not p or p["cmd_id"] != data.get("cmd_id"):
            log.info("stale/unknown ack from %s: %s", device_id, data.get("cmd_id"))
            return
        del pending[key]
        rtt = time.time() - p["sent_at"]
    status = data.get("status")
    audit(device_id, "cmd_ack", {"cmd_id": p["cmd_id"], "status": status,
                                 "fan": data.get("fan"), "rtt_s": round(rtt, 2)})
    log.info("ACK %s %s fan=%s", device_id, status, data.get("fan"))
    if status != "ok":
        notify(device_id, f"Lệnh quạt bị từ chối/không thực hiện: {status} {data.get('reason', '')}")


def check_timeouts(client):
    now = time.time()
    with lock:
        for key, p in list(pending.items()):
            if now - p["sent_at"] < ACK_TIMEOUT_S:
                continue
            if p["retries"] < MAX_RETRIES:
                # Giữ nguyên cmd_id (thiết bị tự chống lặp), làm mới ts để không bị coi là quá hạn
                issue_cmd(client, key, p["value"], p["cmd_id"], p["retries"] + 1)
            else:
                del pending[key]
                audit(key[1], "cmd_failed", {"cmd_id": p["cmd_id"], "value": p["value"]})
                notify(key[1], f"Lệnh quạt '{p['value']}' KHÔNG có ACK sau {MAX_RETRIES} lần thử lại")


def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code.is_failure:
        log.error("MQTT connect failed: %s", reason_code)
        return
    log.info("MQTT connected (T_HIGH=%s T_LOW=%s CONFIRM_N=%s)", T_HIGH, T_LOW, CONFIRM_N)
    client.subscribe([("iot/v1/+/+/telemetry", 0), ("iot/v1/+/+/ack", 1)])


def on_message(client, userdata, msg):
    m = TOPIC_RE.match(msg.topic)
    if not m:
        return
    site, device_id, kind = m.groups()
    try:
        data = json.loads(msg.payload)
        if kind == "telemetry":
            process_telemetry(client, (site, device_id), data)
        else:
            process_ack((site, device_id), data)
    except (ValueError, KeyError, TypeError) as e:
        log.warning("bad message on %s: %s", msg.topic, e)


stop = threading.Event()
signal.signal(signal.SIGTERM, lambda *_: stop.set())

client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="episense-alerter")
client.username_pw_set(MQTT_USER, MQTT_PASS)
client.on_connect = on_connect
client.on_message = on_message
client.reconnect_delay_set(min_delay=1, max_delay=30)
client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
client.loop_start()

while not stop.is_set():
    check_timeouts(client)
    stop.wait(1)

client.loop_stop()
client.disconnect()