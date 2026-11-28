import RequireAuth from './RequireAuth';
import Dashboard from './dashboard/Dashboard';

export default function DashboardApp() {
    return (
        <RequireAuth>
            <Dashboard />
        </RequireAuth>
    );
}