import { useEffect, useState } from 'react';
import RequireAuth from './RequireAuth';
import { api, useAuth } from '../lib/auth';

function Content() {
    const auth = useAuth();
    const [devices, setDevices] = useState<unknown>(null);

    useEffect(() => {
        api('/api/v1/devices')
            .then((r) => (r.ok ? r.json() : null))
            .then(setDevices)
            .catch(() => setDevices(null));
    }, []);

    return (
        <>
            <p>Xin chào {auth.status === 'authenticated' ? `${auth.user.user} (${auth.user.role})` : ''}.</p>
            <p>Khung dashboard thật sẽ được xây ở bước 2.5c. Dữ liệu thử từ API:</p>
            <pre>{JSON.stringify(devices, null, 2)}</pre>
        </>
    );
}

export default function DashboardApp() {
    return (
        <RequireAuth>
            <Content />
        </RequireAuth>
    );
}