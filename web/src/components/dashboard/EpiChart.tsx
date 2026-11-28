import { memo, useEffect, useMemo, useState } from 'react';
import { CartesianGrid, ComposedChart, Line, ReferenceArea, ReferenceLine, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import type { Point } from '../../lib/data';
import type { Episode } from '../../lib/episodes';
import { T_HIGH, T_LOW } from '../../lib/config';
import { formatClock, formatDateTime } from '../../lib/format';
import { usePrefersReducedMotion } from '../../lib/hooks';

/** Chỉ vẽ động trong ~1,4 giây sau khi đổi thiết bị hoặc khoảng thời gian; cập nhật sau đó thì không. */
function useDrawOnce(key: string, enabled: boolean) {
    const [animate, setAnimate] = useState(enabled);
    useEffect(() => {
        setAnimate(enabled);
        if (!enabled) return;
        const id = setTimeout(() => setAnimate(false), 1400);
        return () => clearTimeout(id);
    }, [key, enabled]);
    return animate;
}

type TipProps = { active?: boolean; payload?: ReadonlyArray<{ dataKey?: unknown; value?: unknown }>; label?: unknown };
function EpiTooltip({ active, payload, label }: TipProps) {
    if (!active || !payload?.length || typeof label !== 'number') return null;
    const get = (k: string) => payload.find((p) => p.dataKey === k)?.value;
    const t = get('temp_c');
    const h = get('hum_pct');
    return (
        <div className="tip">
            <p className="when">{formatDateTime(label)}</p>
            <p>Nhiệt độ <strong>{typeof t === 'number' ? `${t.toFixed(1)} °C` : '–'}</strong></p>
            <p>Độ ẩm <strong>{typeof h === 'number' ? `${h.toFixed(0)} %` : '–'}</strong></p>
        </div>
    );
}

type Props = { points: Point[]; episodes: Episode[]; hours: number; rangeKey: string };

function EpiChart({ points, episodes, hours, rangeKey }: Props) {
    const reduce = usePrefersReducedMotion();
    const animate = useDrawOnce(rangeKey, !reduce);

    // Đợt cảnh báo cắt theo khoảng dữ liệu đang hiển thị
    const areas = useMemo(() => {
        const min = points[0].t;
        const max = points[points.length - 1].t;
        return episodes
            .map((e) => ({ x1: Math.max(e.start, min), x2: Math.min(e.end ?? max, max) }))
            .filter((a) => a.x2 > a.x1);
    }, [points, episodes]);

    return (
        <div className="chart" role="img" aria-label="Biểu đồ nhiệt độ và độ ẩm theo thời gian, kèm vạch ngưỡng và các đợt cảnh báo">
            <ResponsiveContainer width="100%" height={340}>
                <ComposedChart data={points} margin={{ top: 12, right: 8, bottom: 0, left: 0 }}>
                    <CartesianGrid stroke="var(--rule)" strokeDasharray="2 4" vertical={false} />
                    <XAxis
                        dataKey="t" type="number" scale="time" domain={['dataMin', 'dataMax']} tickCount={6}
                        tickFormatter={(v: number) => (hours > 24 ? formatDateTime(v) : formatClock(v))}
                        stroke="var(--muted)" tickLine={false}
                    />
                    <YAxis
                        yAxisId="temp" width={40} tickLine={false} axisLine={false} stroke="var(--muted)"
                        domain={[
                            (dataMin: number) => Math.floor(Math.min(dataMin, T_LOW) - 2),
                            (dataMax: number) => Math.ceil(Math.max(dataMax, T_HIGH) + 1),
                        ]}
                        tickFormatter={(v: number) => `${v}°`}
                    />
                    <YAxis
                        yAxisId="hum" orientation="right" width={44} tickLine={false} axisLine={false} stroke="var(--muted)"
                        domain={[0, 100]} tickFormatter={(v: number) => `${v}%`}
                    />
                    {areas.map((a, i) => (
                        <ReferenceArea key={i} yAxisId="temp" x1={a.x1} x2={a.x2} fill="var(--eosin)" fillOpacity={0.14} stroke="none" />
                    ))}
                    <ReferenceLine
                        yAxisId="temp" y={T_HIGH} stroke="var(--eosin)" strokeDasharray="6 4"
                        label={{ value: `Ngưỡng cảnh báo ${T_HIGH} °C`, position: 'insideTopLeft', fill: 'var(--eosin-ink)', fontSize: 12 }}
                    />
                    <ReferenceLine
                        yAxisId="temp" y={T_LOW} stroke="var(--amber)" strokeDasharray="2 4"
                        label={{ value: `Đóng cảnh báo ${T_LOW} °C`, position: 'insideBottomLeft', fill: 'var(--amber-ink)', fontSize: 12 }}
                    />
                    <Tooltip content={<EpiTooltip />} cursor={{ stroke: 'var(--ink-soft)', strokeDasharray: '3 3' }} isAnimationActive={false} />
                    <Line yAxisId="temp" dataKey="temp_c" name="Nhiệt độ" stroke="var(--methylene)" strokeWidth={2.4} dot={false}
                        connectNulls={false} isAnimationActive={animate} animationDuration={1000} animationEasing="ease-out" />
                    <Line yAxisId="hum" dataKey="hum_pct" name="Độ ẩm" stroke="var(--agar)" strokeWidth={1.6} strokeDasharray="5 4" dot={false}
                        connectNulls={false} isAnimationActive={animate} animationDuration={1000} animationEasing="ease-out" />
                </ComposedChart>
            </ResponsiveContainer>
        </div>
    );
}

export default memo(EpiChart); // số đo trực tiếp làm Readout cập nhật liên tục, nhưng không vẽ lại biểu đồ