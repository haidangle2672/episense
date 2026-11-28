import { api } from './auth';

export type Device = { device_id: string; site: string; state: 'online' | 'offline'; updated_at: string };
export type Reading = { time: string; site?: string; temp_c: number | null; hum_pct: number | null };
export type Point = { t: number; temp_c: number | null; hum_pct: number | null };
export type AlertEvent = { id?: number; time: string; device_id: string; kind: string; detail: Record<string, unknown> };

async function getJson<T>(path: string): Promise<T> {
    const r = await api(path);
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return r.json() as Promise<T>;
}

export const fetchDevices = () => getJson<Device[]>('/api/v1/devices');
export const fetchAlerts = (limit = 100) => getJson<AlertEvent[]>(`/api/v1/alerts?limit=${limit}`);
export const fetchLatest = (id: string) =>
    getJson<Reading>(`/api/v1/devices/${encodeURIComponent(id)}/latest`).catch(() => null);

// Chèn điểm rỗng khi mất dữ liệu quá 3 khoảng, để đường bị ngắt: khoảng trống cũng là thông tin
function withGaps(points: Point[], bucketMs: number): Point[] {
    const out: Point[] = [];
    for (const p of points) {
        const prev = out[out.length - 1];
        if (prev && p.t - prev.t > bucketMs * 3) out.push({ t: prev.t + bucketMs, temp_c: null, hum_pct: null });
        out.push(p);
    }
    return out;
}

export async function fetchSeries(id: string, hours: number, bucketS: number): Promise<Point[]> {
    const rows = await getJson<{ t: string; temp_c: number | null; hum_pct: number | null }[]>(
        `/api/v1/devices/${encodeURIComponent(id)}/telemetry?hours=${hours}&bucket_s=${bucketS}`,
    );
    const pts = rows.map((r) => ({ t: Date.parse(r.t), temp_c: r.temp_c, hum_pct: r.hum_pct }));
    return withGaps(pts, bucketS * 1000);
}