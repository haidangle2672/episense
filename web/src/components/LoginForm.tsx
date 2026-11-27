import { useState, type FormEvent } from 'react';
import { login } from '../lib/auth';

// Chỉ cho phép chuyển hướng tới đường dẫn nội bộ (chống open redirect)
function safeNext(raw: string | null): string {
    if (!raw || !raw.startsWith('/') || raw.startsWith('//') || raw.includes('\\')) return '/dashboard/';
    return raw;
}

export default function LoginForm() {
    const [username, setUsername] = useState('');
    const [password, setPassword] = useState('');
    const [error, setError] = useState<string | null>(null);
    const [busy, setBusy] = useState(false);

    async function onSubmit(e: FormEvent) {
        e.preventDefault();
        setBusy(true);
        setError(null);
        try {
            await login(username, password);
            const next = safeNext(new URLSearchParams(window.location.search).get('next'));
            window.location.assign(next);
        } catch (err) {
            setError(err instanceof Error ? err.message : 'Đã xảy ra lỗi');
            setPassword('');
            setBusy(false);
        }
    }

    return (
        <form className="login" onSubmit={onSubmit}>
            <label>
                Tên đăng nhập
                <input value={username} onChange={(e) => setUsername(e.target.value)}
                    autoComplete="username" required maxLength={64} />
            </label>
            <label>
                Mật khẩu
                <input type="password" value={password} onChange={(e) => setPassword(e.target.value)}
                    autoComplete="current-password" required maxLength={256} />
            </label>
            <button type="submit" disabled={busy}>{busy ? 'Đang đăng nhập…' : 'Đăng nhập'}</button>
            {error && <p role="alert">{error}</p>}
        </form>
    );
}