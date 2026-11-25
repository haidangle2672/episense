# api/app/realtime.py
import asyncio
import json
import logging

log = logging.getLogger("realtime")
INTERVAL_S = 2.0   # chu kỳ poll DB


def _default(o):                      # datetime -> chuỗi ISO 8601 (JS parse được)
    return o.isoformat() if hasattr(o, "isoformat") else str(o)


class Hub:
    """Phát sự kiện tới nhiều client SSE trong cùng 1 process."""

    def __init__(self, max_clients: int = 50):
        self.max_clients = max_clients
        self.clients: set[asyncio.Queue] = set()
        self.state: dict[str, str] = {}      # tin mới nhất mỗi thiết bị, gửi cho client mới vào

    def subscribe(self):
        if len(self.clients) >= self.max_clients:
            return None
        q = asyncio.Queue(maxsize=100)       # trần: client chậm không làm phình RAM
        self.clients.add(q)
        return q

    def unsubscribe(self, q):
        self.clients.discard(q)

    def snapshot_messages(self):
        return list(self.state.values())

    def publish(self, event: str, key: str | None, data: dict):
        msg = f"event: {event}\ndata: {json.dumps(data, default=_default)}\n\n"
        if key:
            self.state[key] = msg
        for q in list(self.clients):
            try:
                q.put_nowait(msg)
            except asyncio.QueueFull:
                self.clients.discard(q)      # client quá chậm: bỏ, EventSource sẽ tự nối lại


SQL_LATEST = """
    SELECT DISTINCT ON (device_id) device_id, site, time, temp_c, hum_pct
    FROM telemetry
    WHERE time > now() - interval '10 minutes'
    ORDER BY device_id, time DESC
"""


async def poll_loop(query, hub: Hub):
    last_ts: dict = {}          # device_id -> time đã phát
    last_state: dict = {}       # device_id -> online/offline đã phát
    last_alert_id = None        # id cảnh báo đã phát
    while True:
        try:
            for r in await query(SQL_LATEST, ()):
                if last_ts.get(r["device_id"]) != r["time"]:
                    last_ts[r["device_id"]] = r["time"]
                    hub.publish("telemetry", f"telemetry:{r['device_id']}", r)

            for r in await query(
                    "SELECT device_id, site, state, updated_at FROM device_status", ()):
                if last_state.get(r["device_id"]) != r["state"]:
                    last_state[r["device_id"]] = r["state"]
                    hub.publish("status", f"status:{r['device_id']}", r)

            if last_alert_id is None:       # lần đầu: chỉ ghi nhớ mốc, không phát lại lịch sử
                rows = await query("SELECT coalesce(max(id), 0) AS m FROM alert_events", ())
                last_alert_id = rows[0]["m"]
            else:
                for r in await query(
                        "SELECT id, time, device_id, kind, detail FROM alert_events "
                        "WHERE id > %s AND kind IN ('alert_open', 'alert_close') "
                        "ORDER BY id", (last_alert_id,)):
                    last_alert_id = r["id"]
                    hub.publish("alert", None, r)
        except Exception as e:              # lỗi DB tạm thời: log tên lỗi, thử lại ở chu kỳ sau
            log.error("poll lỗi: %s", type(e).__name__)
        await asyncio.sleep(INTERVAL_S)