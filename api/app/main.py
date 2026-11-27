# api/app/main.py
import os
import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Path, Query, Request, Depends, Response
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool
from fastapi.responses import StreamingResponse
from app.realtime import Hub, poll_loop
from pydantic import BaseModel, Field
from app import auth

hub = Hub()

DEVICE_ID = Path(pattern=r"^[A-Za-z0-9_-]{1,32}$")  # whitelist ký tự
MAX_POINTS = 2000                                    # trần số điểm mỗi lần trả về

pool = AsyncConnectionPool(
    conninfo="",
    kwargs=dict(
        host=os.environ.get("DB_HOST", "db"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["API_DB_USER"],
        password=os.environ["API_DB_PASS"],
        row_factory=dict_row,
    ),
    min_size=1, max_size=5, open=False,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await pool.open()
    task = asyncio.create_task(poll_loop(query, hub))   # 1 vòng poll chung
    yield
    task.cancel()
    await pool.close()


app = FastAPI(
    title="EpiSense API", version="1", lifespan=lifespan,
    dependencies=[Depends(auth.require_user)],        # mọi route đều phải đăng nhập
    docs_url=None, redoc_url=None, openapi_url=None,  # tắt tài liệu tự sinh
)


async def query(sql: str, params: tuple):
    async with pool.connection() as conn:
        cur = await conn.execute(sql, params)
        return await cur.fetchall()


@app.get("/healthz")
async def healthz():
    await query("SELECT 1", ())          # kiểm tra cả đường tới DB
    return {"ok": True}


@app.get("/api/v1/devices")
async def devices():
    # liệt kê cột rõ ràng thay vì SELECT *
    return await query(
        "SELECT device_id, site, state, updated_at FROM device_status "
        "ORDER BY device_id", ())


@app.get("/api/v1/devices/{device_id}/latest")
async def latest(device_id: str = DEVICE_ID):
    rows = await query(
        "SELECT time, site, temp_c, hum_pct FROM telemetry "
        "WHERE device_id = %s ORDER BY time DESC LIMIT 1", (device_id,))
    if not rows:
        raise HTTPException(404, "device not found")
    return rows[0]


@app.get("/api/v1/devices/{device_id}/telemetry")
async def telemetry(
    device_id: str = DEVICE_ID,
    hours: int = Query(1, ge=1, le=168),         # tối đa 7 ngày
    bucket_s: int = Query(60, ge=10, le=3600),   # gộp theo N giây
):
    if hours * 3600 // bucket_s > MAX_POINTS:
        raise HTTPException(422, f"quá nhiều điểm (>{MAX_POINTS}), hãy tăng bucket_s")
    return await query(
        "SELECT time_bucket(%s * interval '1 second', time) AS t, "
        "avg(temp_c) AS temp_c, avg(hum_pct) AS hum_pct "
        "FROM telemetry "
        "WHERE device_id = %s AND time > now() - %s * interval '1 hour' "
        "GROUP BY t ORDER BY t", (bucket_s, device_id, hours))


@app.get("/api/v1/alerts")
async def alerts(device_id: str | None = Query(None, pattern=r"^[A-Za-z0-9_-]{1,32}$"),
                 limit: int = Query(20, ge=1, le=100)):
    return await query(
        "SELECT time, device_id, kind, detail FROM alert_events "
        "WHERE (%s::text IS NULL OR device_id = %s) "
        "ORDER BY time DESC LIMIT %s", (device_id, device_id, limit))

@app.get("/api/v1/stream")
async def stream(request: Request):
    q = hub.subscribe()
    if q is None:
        raise HTTPException(503, "quá nhiều client")

    async def gen():
        try:
            yield "retry: 3000\n\n"              # trình duyệt tự nối lại sau 3 giây
            for msg in hub.snapshot_messages():  # client mới vào có số liệu ngay
                yield msg
            while True:
                try:
                    yield await asyncio.wait_for(q.get(), timeout=15)
                except asyncio.TimeoutError:
                    if q not in hub.clients:     # đã bị loại vì quá chậm
                        break
                    yield ": ping\n\n"           # heartbeat giữ kết nối qua proxy
        finally:
            hub.unsubscribe(q)                   # luôn dọn khi client ngắt

    return StreamingResponse(
        gen(), media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
        

class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)

@app.post("/api/v1/auth/login")
async def login(body: LoginIn, request: Request, response: Response):
    ip = request.client.host if request.client else "unknown"
    username = body.username.strip().lower()
    if auth.is_blocked(ip, username):
        raise HTTPException(429, "thu lai sau")
    rows = await query(
        "SELECT username, password_hash, role FROM app_users WHERE username = %s", (username,))
    row = rows[0] if rows else None
    ok = await asyncio.to_thread(
        auth.verify_password, row["password_hash"] if row else None, body.password)
    if not ok:
        auth.record_failure(ip, username)
        raise HTTPException(401, "sai ten dang nhap hoac mat khau")   # thông báo chung, không lộ user có tồn tại
    auth.record_success(ip, username)
    response.set_cookie(
        auth.COOKIE, auth.make_token(row["username"], row["role"]),
        max_age=auth.TTL_S, httponly=True, secure=True, samesite="lax", path="/")
    return {"user": row["username"], "role": row["role"]}

@app.post("/api/v1/auth/logout")
async def logout(response: Response):
    response.delete_cookie(auth.COOKIE, path="/", secure=True, httponly=True, samesite="lax")
    return {"ok": True}

@app.get("/api/v1/auth/me")
async def me(request: Request):
    return {"user": request.state.user["u"], "role": request.state.user["r"]}