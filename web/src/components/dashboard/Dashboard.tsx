import { useEffect, useMemo, useState } from 'react';
import './dashboard.css';
import { fetchAlerts, fetchDevices, fetchLatest, fetchSeries, type AlertEvent, type Device, type Point, type Reading } from '../../lib/data';
import { RANGES } from '../../lib/config';
import { buildEpisodes } from '../../lib/episodes';
import { useLiveStream } from '../../lib/hooks';
import Readout from './Readout';
import EpiChart from './EpiChart';
import EpisodeList from './EpisodeList';

export default function Dashboard() {
    const [devices, setDevices] = useState<Device[] | null>(null);
    const [selected, setSelected] = useState<string | null>(null);
    const [rangeId, setRangeId] = useState<string>('6h');
    const [latest, setLatest] = useState<Record<string, Reading>>({});
    const [series, setSeries] = useState<Point[] | null>(null);
    const [alerts, setAlerts] = useState<AlertEvent[]>([]);
    const [flash, setFlash] = useState<number | null>(null);
    const [loadError, setLoadError] = useState(false);

    const range = RANGES.find((r) => r.id === rangeId) ?? RANGES[1];

    // 1) Danh sách thiết bị và nhật ký cảnh báo
    useEffect(() => {
        let cancelled = false;
        Promise.all([fetchDevices(), fetchAlerts()])
            .then(([d, a]) => {
                if (cancelled) return;
                setDevices(d);
                setAlerts(a);
                setSelected((s) => s ?? d[0]?.device_id ?? null);
            })
            .catch(() => {
                if (!cancelled) setLoadError(true);
            });
        return () => {
            cancelled = true;
        };
    }, []);

    // 2) Số đo mới nhất của thiết bị đang chọn (sau đó SSE sẽ cập nhật)
    useEffect(() => {
        if (!selected) return;
        let cancelled = false;
        fetchLatest(selected).then((r) => {
            if (!cancelled && r) setLatest((m) => ({ ...m, [selected]: r }));
        });
        return () => {
            cancelled = true;
        };
    }, [selected]);

    // 3) Chuỗi thời gian cho biểu đồ, làm mới mỗi 30 giây
    useEffect(() => {
        if (!selected) return;
        let cancelled = false;
        setSeries(null);
        const load = () =>
            fetchSeries(selected, range.hours, range.bucketS)
                .then((p) => {
                    if (!cancelled) setSeries(p);
                })
                .catch(() => {
                    if (!cancelled) setSeries((s) => s ?? []);
                });
        void load();
        const id = setInterval(load, 30_000);
        return () => {
            cancelled = true;
            clearInterval(id);
        };
    }, [selected, range.hours, range.bucketS]);

    // 4) Sự kiện trực tiếp
    const live = useLiveStream((type, data) => {
        if (type === 'telemetry') {
            setLatest((m) => ({ ...m, [data.device_id]: data }));
        } else if (type === 'status') {
            setDevices((list) =>
                list ? list.map((d) => (d.device_id === data.device_id ? { ...d, state: data.state, updated_at: data.updated_at } : d)) : list,
            );
        } else if (type === 'alert') {
            setAlerts((list) => (list.some((e) => e.id === data.id) ? list : [data, ...list]));
            if (data.kind === 'alert_open') setFlash(Date.parse(data.time));
        }
    });

    const episodes = useMemo(() => (selected ? buildEpisodes(alerts, selected) : []), [alerts, selected]);
    const active = episodes.length > 0 && episodes[episodes.length - 1].end === null;
    const current = selected ? latest[selected] : undefined;

    if (loadError) return <p role="alert">Không tải được danh sách thiết bị. Kiểm tra kết nối rồi tải lại trang.</p>;
    if (!devices) return <p>Đang tải dữ liệu…</p>;
    if (devices.length === 0) return <p>Chưa có thiết bị nào gửi dữ liệu. Khi ESP32 kết nối, thiết bị sẽ hiện ở đây.</p>;

    return (
        <div className="dash">
            <div className="dash-head">
                <div className="rack" role="tablist" aria-label="Thiết bị">
                    {devices.map((d) => (
                        <button key={d.device_id} role="tab" aria-selected={d.device_id === selected} onClick={() => setSelected(d.device_id)}>
                            <span className="state-dot" data-state={d.state} aria-hidden="true" />
                            {d.device_id}
                            <span className="sub">{d.site}</span>
                            <span className="sr-only">{d.state === 'online' ? 'trực tuyến' : 'ngoại tuyến'}</span>
                        </button>
                    ))}
                </div>
                <p className="live" data-live={live}>
                    {live === 'live' ? 'Trực tiếp' : live === 'connecting' ? 'Đang kết nối…' : 'Mất kết nối, đang thử lại'}
                </p>
            </div>

            <div className="field-layout">
                <Readout reading={current} activeAlert={active} />

                <section className="trace" aria-labelledby="trace-title">
                    <header>
                        <h2 id="trace-title">Đường cong theo dõi</h2>
                        <div className="ranges" role="group" aria-label="Khoảng thời gian">
                            {RANGES.map((r) => (
                                <button key={r.id} aria-pressed={r.id === rangeId} onClick={() => setRangeId(r.id)}>
                                    {r.label}
                                </button>
                            ))}
                        </div>
                    </header>
                    {series === null ? (
                        <div className="chart-skeleton" aria-busy="true">Đang tải số liệu…</div>
                    ) : series.length === 0 ? (
                        <div className="chart-empty">Chưa có số đo trong {range.label} gần nhất. Hãy thử khoảng thời gian dài hơn.</div>
                    ) : (
                        <EpiChart points={series} episodes={episodes} hours={range.hours} rangeKey={`${selected}:${rangeId}`} />
                    )}
                </section>
            </div>

            <section className="log" aria-labelledby="log-title">
                <h2 id="log-title">Các đợt cảnh báo</h2>
                <EpisodeList episodes={episodes} flashStart={flash} />
            </section>
        </div>
    );
}