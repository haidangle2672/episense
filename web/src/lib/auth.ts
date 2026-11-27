import { useEffect, useSyncExternalStore } from 'react';

export type User = { user: string; role: 'admin' | 'viewer' };
export type AuthState =
    | { status: 'loading' }
    | { status: 'anonymous' }
    | { status: 'error' }
    | { status: 'authenticated'; user: User };

const LOADING: AuthState = { status: 'loading' };
let state: AuthState = LOADING;
const listeners = new Set<() => void>();

function set(next: AuthState) {
    state = next;
    listeners.forEach((l) => l());
}
function subscribe(l: () => void) {
    listeners.add(l);
    return () => {
        listeners.delete(l);
    };
}
const getState = () => state;

let inflight: Promise<void> | null = null;

/** Hỏi server "tôi là ai". Nhiều island gọi cùng lúc thì chỉ gửi một request. */
export function refresh(): Promise<void> {
    inflight ??= (async () => {
        try {
            const r = await fetch('/api/v1/auth/me', { credentials: 'same-origin', cache: 'no-store' });
            if (r.ok) set({ status: 'authenticated', user: await r.json() });
            else if (r.status === 401) set({ status: 'anonymous' });
            else set({ status: 'error' });
        } catch {
            set({ status: 'error' });
        } finally {
            inflight = null;
        }
    })();
    return inflight;
}

/** fetch dùng cho mọi lời gọi API: gặp 401 thì đánh dấu phiên đã hết. */
export async function api(path: string, init: RequestInit = {}): Promise<Response> {
    const r = await fetch(path, { credentials: 'same-origin', cache: 'no-store', ...init });
    if (r.status === 401) set({ status: 'anonymous' });
    return r;
}

export async function login(username: string, password: string): Promise<void> {
    let r: Response;
    try {
        r = await fetch('/api/v1/auth/login', {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username, password }),
        });
    } catch {
        throw new Error('Không kết nối được máy chủ');
    }
    if (r.status === 401) throw new Error('Sai tên đăng nhập hoặc mật khẩu');
    if (r.status === 429) throw new Error('Thử quá nhiều lần. Vui lòng đợi 15 phút rồi thử lại');
    if (r.status === 422) throw new Error('Dữ liệu không hợp lệ');
    if (!r.ok) throw new Error('Lỗi máy chủ, vui lòng thử lại sau');
    await refresh();
}

export async function logout(): Promise<void> {
    try {
        await fetch('/api/v1/auth/logout', { method: 'POST', credentials: 'same-origin' });
    } catch {
        /* mạng lỗi: refresh bên dưới sẽ phản ánh đúng trạng thái thật */
    }
    await refresh();
}

export function useAuth(): AuthState {
    const s = useSyncExternalStore(subscribe, getState, () => LOADING);
    useEffect(() => {
        if (getState().status === 'loading') void refresh();
    }, []);
    return s;
}