import { useState } from 'react';

export default function HydrationCheck() {
    const [n, setN] = useState(0);
    return (
        <button type="button" onClick={() => setN(n + 1)}>
            React hoạt động: đã bấm {n} lần
        </button>
    );
}