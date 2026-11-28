import { T_HIGH } from '../../lib/config';
import { formatDateTime, formatDuration } from '../../lib/format';
import type { Episode } from '../../lib/episodes';

export default function EpisodeList({ episodes, flashStart }: { episodes: Episode[]; flashStart: number | null }) {
    const rows = [...episodes].reverse().slice(0, 12);
    if (rows.length === 0) {
        return <p className="empty">Chưa có đợt cảnh báo nào. Khi nhiệt độ vượt {T_HIGH} °C liên tiếp, đợt cảnh báo sẽ xuất hiện ở đây.</p>;
    }
    return (
        <table className="episodes">
            <caption className="sr-only">Các đợt cảnh báo gần đây của thiết bị đang chọn</caption>
            <thead>
                <tr>
                    <th scope="col">Bắt đầu</th>
                    <th scope="col">Kết thúc</th>
                    <th scope="col">Kéo dài</th>
                    <th scope="col">Nhiệt độ khi mở</th>
                </tr>
            </thead>
            <tbody>
                {rows.map((e) => (
                    <tr key={e.start} className={e.end === null ? 'ongoing' : undefined} data-flash={flashStart === e.start || undefined}>
                        <td>{formatDateTime(e.start)}</td>
                        <td>{e.end === null ? 'Đang diễn ra' : formatDateTime(e.end)}</td>
                        <td>{formatDuration((e.end ?? Date.now()) - e.start)}</td>
                        <td>{e.tempOpen === null ? '–' : `${e.tempOpen.toFixed(1)} °C`}</td>
                    </tr>
                ))}
            </tbody>
        </table>
    );
}