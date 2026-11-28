import type { AlertEvent } from './data';

export type Episode = { start: number; end: number | null; tempOpen: number | null };

/** Ghép cặp alert_open / alert_close thành các đợt cảnh báo (cũ trước, mới sau). */
export function buildEpisodes(events: AlertEvent[], deviceId: string): Episode[] {
    const rows = events
        .filter((e) => e.device_id === deviceId && (e.kind === 'alert_open' || e.kind === 'alert_close'))
        .sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
    const out: Episode[] = [];
    let open: Episode | null = null;
    for (const e of rows) {
        const t = Date.parse(e.time);
        if (e.kind === 'alert_open') {
            const temp = typeof e.detail?.temp_c === 'number' ? e.detail.temp_c : null;
            open = { start: t, end: null, tempOpen: temp };
            out.push(open);
        } else if (open) {
            open.end = t;
            open = null;
        }
    }
    return out;
}