# api/app/auth.py
import os
import time

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import HTTPException, Request
from itsdangerous import BadSignature, URLSafeTimedSerializer

SECRET = os.environ["SESSION_SECRET"]
TTL_S = int(os.environ.get("SESSION_TTL_S", 12 * 3600))   # phiên sống 12 giờ
COOKIE = "__Host-episense_session"    # tiền tố __Host-: bắt buộc Secure + Path=/ + không Domain

# Chỉ những đường dẫn này không cần đăng nhập
PUBLIC_PATHS = {"/healthz", "/api/v1/auth/login", "/api/v1/auth/logout"}

_ph = PasswordHasher()
_ser = URLSafeTimedSerializer(SECRET, salt="episense-session-v1")
_DUMMY_HASH = _ph.hash("dummy-password-for-constant-time")


def verify_password(stored_hash, password) -> bool:
    """Chạy trong thread. Tốn thời gian như nhau dù user có tồn tại hay không."""
    try:
        _ph.verify(stored_hash or _DUMMY_HASH, password)
        return stored_hash is not None
    except (VerificationError, InvalidHashError):
        return False


def make_token(username: str, role: str) -> str:
    return _ser.dumps({"u": username, "r": role})


def read_session(request: Request):
    token = request.cookies.get(COOKIE)
    if not token:
        return None
    try:
        data = _ser.loads(token, max_age=TTL_S)   # sai chữ ký hoặc hết hạn thì BadSignature
    except BadSignature:
        return None
    return data if isinstance(data, dict) and "u" in data else None


async def require_user(request: Request):
    """Dependency toàn cục: deny by default."""
    if request.url.path in PUBLIC_PATHS:
        return
    session = read_session(request)
    if session is None:
        raise HTTPException(status_code=401, detail="not authenticated")
    request.state.user = session


# ---- Giới hạn đăng nhập sai (trong RAM, 1 worker) ----
_FAILS: dict = {}
LIMIT_IP, LIMIT_IP_USER, WINDOW_S = 20, 5, 900


def _recent(key: str) -> list:
    now = time.time()
    xs = [t for t in _FAILS.get(key, []) if now - t < WINDOW_S]
    if xs:
        _FAILS[key] = xs
    else:
        _FAILS.pop(key, None)
    return xs


def is_blocked(ip: str, username: str) -> bool:
    return (len(_recent(f"ip:{ip}")) >= LIMIT_IP
            or len(_recent(f"ipuser:{ip}|{username}")) >= LIMIT_IP_USER)


def record_failure(ip: str, username: str) -> None:
    if len(_FAILS) > 10000:      # trần bộ nhớ
        _FAILS.clear()
    for key in (f"ip:{ip}", f"ipuser:{ip}|{username}"):
        _FAILS.setdefault(key, []).append(time.time())


def record_success(ip: str, username: str) -> None:
    _FAILS.pop(f"ipuser:{ip}|{username}", None)