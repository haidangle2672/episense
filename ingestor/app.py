import json
import logging
import os
import re
import signal
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import psycopg

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ingestor")

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

# iot/v1/{site}/{device_id}/{telemetry|status}
TOPIC_RE = re.compile(r"^iot/v1/([\w-]+)/([\w-]+)/(telemetry|status)$")


class Db:
    """Giữ 1 kết nối, tự nối lại khi DB mất kết nối."""

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


def handle_telemetry(site, device_id, data):
    if data.get("v") != 1:
        raise ValueError("unsupported payload version")
    ts = int(data["ts"])
    temp = float(data["temp_c"])
    hum = float(data["hum_pct"])
    if not (-40 <= temp <= 80 and 0 <= hum <= 100):
        raise ValueError(f"value out of range: temp={temp} hum={hum}")
    if abs(ts - time.time()) > 86400:
        raise ValueError("timestamp too far from server time")

    ok = db.execute(
        """INSERT INTO telemetry (time, site, device_id, temp_c, hum_pct, seq)
           VALUES (%s, %s, %s, %s, %s, %s)
           ON CONFLICT DO NOTHING""",
        (datetime.fromtimestamp(ts, tz=timezone.utc), site, device_id,
         temp, hum, data.get("seq")),
    )
    if not ok:
        log.error("DROPPED telemetry from %s (DB unavailable)", device_id)


def handle_status(site, device_id, data):
    state = data.get("state")
    if state not in ("online", "offline"):
        raise ValueError(f"invalid state: {state}")
    db.execute(
        """INSERT INTO device_status (device_id, site, state, updated_at)
           VALUES (%s, %s, %s, now())
           ON CONFLICT (device_id) DO UPDATE
           SET site = EXCLUDED.site, state = EXCLUDED.state, updated_at = now()""",
        (device_id, site, state),
    )
    log.info("status %s -> %s", device_id, state)


def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code.is_failure:
        log.error("MQTT connect failed: %s", reason_code)
        return
    log.info("MQTT connected")
    # Subscribe trong on_connect để tự subscribe lại sau mỗi lần reconnect
    client.subscribe([("iot/v1/+/+/telemetry", 1), ("iot/v1/+/+/status", 1)])


def on_message(client, userdata, msg):
    m = TOPIC_RE.match(msg.topic)
    if not m:
        log.warning("ignored topic %s", msg.topic)
        return
    site, device_id, kind = m.groups()   # tin topic, không tin payload
    try:
        data = json.loads(msg.payload)
        if kind == "telemetry":
            handle_telemetry(site, device_id, data)
        else:
            handle_status(site, device_id, data)
    except (ValueError, KeyError, TypeError) as e:
        log.warning("bad message on %s: %s | %r", msg.topic, e, msg.payload[:200])


client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="episense-ingestor")
client.username_pw_set(MQTT_USER, MQTT_PASS)
client.on_connect = on_connect
client.on_message = on_message
client.reconnect_delay_set(min_delay=1, max_delay=30)

signal.signal(signal.SIGTERM, lambda *_: client.disconnect())  # docker stop thoát êm

client.connect_async(MQTT_HOST, MQTT_PORT, keepalive=30)
client.loop_forever()