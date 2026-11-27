#!/usr/bin/env bash
# Tạo hoặc đổi mật khẩu người dùng: tools/add-user.sh <username> [admin|viewer]
set -euo pipefail
cd "$(dirname "$0")/.."

user="${1:?usage: tools/add-user.sh <username> [admin|viewer]}"
user="${user,,}"                      # chữ thường
role="${2:-viewer}"
case "$role" in admin|viewer) ;; *) echo "role phai la admin hoac viewer"; exit 1 ;; esac

read -rsp "Mat khau cho $user (toi thieu 12 ky tu): " pw; echo
read -rsp "Nhap lai: " pw2; echo
[ "$pw" = "$pw2" ] || { echo "Khong khop"; exit 1; }
[ "${#pw}" -ge 12 ] || { echo "Qua ngan"; exit 1; }

# Mật khẩu đi qua stdin, không nằm trong dòng lệnh
hash=$(printf '%s' "$pw" | docker compose exec -T api python -c "import sys; from argon2 import PasswordHasher; print(PasswordHasher().hash(sys.stdin.read()))")

docker compose exec -T db psql -U episense -d episense -v ON_ERROR_STOP=1 \
  -v u="$user" -v r="$role" -v h="$hash" <<'SQL'
INSERT INTO app_users (username, password_hash, role) VALUES (:'u', :'h', :'r')
ON CONFLICT (username) DO UPDATE SET password_hash = EXCLUDED.password_hash, role = EXCLUDED.role;
SQL
echo "Da luu $user ($role)"