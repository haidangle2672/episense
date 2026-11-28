import { useNow } from '../../lib/hooks';
import { formatAgo } from '../../lib/format';
import { T_HIGH, T_LOW } from '../../lib/config';
import type { Reading } from '../../lib/data';

const MIN = 20, MAX = 45, R = 92, C = 2 * Math.PI * R;
const frac = (t: number) => Math.min(1, Math.max(0, (t - MIN) / (MAX - MIN)));

type Level = 'normal' | 'watch' | 'alert' | 'stale' | 'empty';
const LABEL: Record<Level, string> = {
    normal: 'Bình thường',
    watch: 'Gần ngưỡng cảnh báo',
    alert: 'Đang cảnh báo',
    stale: 'Mất tín hiệu',
    empty: 'Chưa có dữ liệu',
};

export default function Readout({ reading, activeAlert }: { reading?: Reading | null; activeAlert: boolean }) {
    const now = useNow(1000);
    const ageS = reading ? Math.max(0, Math.round((now - Date.parse(reading.time)) / 1000)) : null;
    const temp = reading?.temp_c ?? null;

    let level: Level = 'empty';
    if (reading && temp !== null && ageS !== null) {
        level = ageS > 90 ? 'stale' : activeAlert ? 'alert' : temp >= T_LOW ? 'watch' : 'normal';
    }
    const arc = temp === null ? 0 : frac(temp) * C;

    return (
        <section className="readout" data-level={level} aria-label="Số đo mới nhất">
            <div className="lens">
                <svg viewBox="0 0 220 220" aria-hidden="true">
                    <circle className="reticle" cx="110" cy="110" r="64" />
                    <circle className="reticle" cx="110" cy="110" r="38" />
                    <path className="reticle" d="M110 14v14M110 192v14M14 110h14M192 110h14" />
                    <circle className="track" cx="110" cy="110" r={R} />
                    <circle className="arc" cx="110" cy="110" r={R} strokeDasharray={`${arc} ${C}`} transform="rotate(-90 110 110)" />
                    {[T_LOW, T_HIGH].map((t) => (
                        <line key={t} className={t === T_HIGH ? 'mark mark-high' : 'mark'} x1="110" y1="6" x2="110" y2="20" transform={`rotate(${frac(t) * 360} 110 110)`} />
                    ))}
                    {reading && <circle key={reading.time} className="halo" cx="110" cy="110" r={R} />}
                </svg>
                <div className="readout-text">
                    <p className="temp">
                        <span className="num">{temp === null ? '–' : temp.toFixed(1)}</span>
                        <span className="unit">°C</span>
                    </p>
                    <p className="hum">
                        Độ ẩm <strong>{reading?.hum_pct == null ? '–' : reading.hum_pct.toFixed(0)}</strong> %
                    </p>
                </div>
            </div>
            <p className="level" aria-live="polite">{LABEL[level]}</p>
            <p className="ago">{ageS === null ? 'Chờ số đo đầu tiên' : `Cập nhật ${formatAgo(ageS)}`}</p>
        </section>
    );
}