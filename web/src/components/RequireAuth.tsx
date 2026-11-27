import { useEffect, type ReactNode } from 'react';
import { useAuth, refresh } from '../lib/auth';

export default function RequireAuth({ children }: { children: ReactNode }) {
    const auth = useAuth();

    useEffect(() => {
        if (auth.status === 'anonymous') {
            const next = encodeURIComponent(window.location.pathname + window.location.search);
            window.location.replace(`/dang-nhap/?next=${next}`);
        }
    }, [auth.status]);

    if (auth.status === 'authenticated') return <>{children}</>;
    if (auth.status === 'error') {
        return (
            <p role="alert">
                Không kiểm tra được phiên đăng nhập. <button type="button" onClick={() => void refresh()}>Thử lại</button>
            </p>
        );
    }
    return <p>Đang kiểm tra phiên đăng nhập…</p>;
}