const dateTime = new Intl.DateTimeFormat('vi-VN', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
const clock = new Intl.DateTimeFormat('vi-VN', { hour: '2-digit', minute: '2-digit' });

export const formatDateTime = (ms: number) => dateTime.format(ms);
export const formatClock = (ms: number) => clock.format(ms);

export function formatDuration(ms: number): string {
    const s = Math.max(0, Math.round(ms / 1000));
    if (s < 60) return `${s} giây`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m} phút`;
    const h = Math.floor(m / 60);
    const rm = m % 60;
    return rm ? `${h} giờ ${rm} phút` : `${h} giờ`;
}

export function formatAgo(s: number): string {
    if (s < 5) return 'vừa xong';
    if (s < 60) return `${s} giây trước`;
    if (s < 3600) return `${Math.floor(s / 60)} phút trước`;
    return `${Math.floor(s / 3600)} giờ trước`;
}