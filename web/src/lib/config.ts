// Phải khớp với T_HIGH và T_LOW của alerter (mặc định 35.0 và 33.0).
// Đổi ngưỡng trong .env của VPS thì sửa ở đây (sau này nên cho API trả về).
export const T_HIGH = 35;
export const T_LOW = 33;

// Ràng buộc của API: bucketS >= 10 và hours*3600/bucketS <= 2000
export const RANGES = [
    { id: '1h', label: '1 giờ', hours: 1, bucketS: 30 },
    { id: '6h', label: '6 giờ', hours: 6, bucketS: 120 },
    { id: '24h', label: '24 giờ', hours: 24, bucketS: 300 },
    { id: '7d', label: '7 ngày', hours: 168, bucketS: 900 },
] as const;