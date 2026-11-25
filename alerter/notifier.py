# alerter/notifier.py
import json
import logging
import os
import queue
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("notifier")

TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "")
_URL = f"https://api.telegram.org/bot{TOKEN}/sendMessage"

_q: "queue.Queue[str]" = queue.Queue(maxsize=100)  # giới hạn để không phình RAM


def send_telegram(text: str, retries: int = 3) -> bool:
    """Gửi 1 tin, có timeout + retry. Trả True nếu thành công."""
    if not TOKEN or not CHAT_ID:
        log.warning("Telegram chưa cấu hình, bỏ qua")
        return False
    body = json.dumps({"chat_id": CHAT_ID, "text": text}).encode()
    req = urllib.request.Request(
        _URL, data=body, headers={"Content-Type": "application/json"}
    )
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:  # timeout bắt buộc
                return resp.status == 200
        except urllib.error.HTTPError as e:
            wait = 2 ** attempt
            if e.code == 429:  # bị giới hạn tốc độ, Telegram báo thời gian chờ
                try:
                    wait = json.loads(e.read())["parameters"]["retry_after"]
                except Exception:
                    pass
            elif 400 <= e.code < 500:  # sai token/chat_id: retry vô ích
                log.error("Telegram từ chối: HTTP %s", e.code)
                return False
            log.warning("Telegram HTTP %s, thử lại sau %ss", e.code, wait)
        except Exception as e:  # chỉ log TÊN lỗi, không log URL (có token)
            wait = 2 ** attempt
            log.warning("Telegram lỗi mạng: %s", type(e).__name__)
        time.sleep(wait)
    return False


def _worker():
    while True:
        text = _q.get()
        if not send_telegram(text):
            log.error("Gửi Telegram thất bại sau khi retry")
        _q.task_done()


threading.Thread(target=_worker, daemon=True, name="telegram-sender").start()


def notify(text: str) -> None:
    """Không chặn: đẩy vào queue rồi quay lại ngay."""
    try:
        _q.put_nowait(text)
    except queue.Full:
        log.error("Queue Telegram đầy, bỏ tin")