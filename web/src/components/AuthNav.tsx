import { useAuth, logout } from '../lib/auth';

export default function AuthNav() {
    const auth = useAuth();
    if (auth.status === 'loading') return <span aria-hidden="true" style={{ minWidth: '8rem', display: 'inline-block' }} />;
    if (auth.status === 'authenticated') {
        return (
            <span>
                {auth.user.user} ({auth.user.role}){' '}
                <button type="button" onClick={() => void logout().then(() => window.location.assign('/'))}>
                    Đăng xuất
                </button>
            </span>
        );
    }
    return <a href="/dang-nhap/">Đăng nhập</a>;
}