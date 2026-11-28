import { useEffect, useRef, useState } from 'react';
import { refresh } from './auth';

export type LiveState = 'connecting' | 'live' | 'down';

/** Nhận sự kiện từ /api/v1/stream (SSE). EventSource tự nối lại khi đứt. */
export function useLiveStream(onEvent: (type: string, data: any) => void): LiveState {
    const [state, setState] = useState<LiveState>('connecting');
    const handler = useRef(onEvent);
    handler.current = onEvent; // luôn gọi bản mới nhất mà không phải mở lại kết nối

    useEffect(() => {
        const es = new EventSource('/api/v1/stream');
        es.onopen = () => setState('live');
        es.onerror = () => {
            setState('down');
            void refresh(); // EventSource không thấy mã 401: hỏi lại xem phiên còn hiệu lực không
        };
        for (const type of ['telemetry', 'status', 'alert']) {
            es.addEventListener(type, (e) => {
                try {
                    handler.current(type, JSON.parse((e as MessageEvent).data));
                } catch {
                    /* bỏ qua tin hỏng */
                }
            });
        }
        return () => es.close();
    }, []);

    return state;
}

export function useNow(intervalMs: number): number {
    const [now, setNow] = useState(() => Date.now());
    useEffect(() => {
        const id = setInterval(() => setNow(Date.now()), intervalMs);
        return () => clearInterval(id);
    }, [intervalMs]);
    return now;
}

export function usePrefersReducedMotion(): boolean {
    const [reduce, setReduce] = useState(false);
    useEffect(() => {
        const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
        const on = () => setReduce(mq.matches);
        on();
        mq.addEventListener('change', on);
        return () => mq.removeEventListener('change', on);
    }, []);
    return reduce;
}