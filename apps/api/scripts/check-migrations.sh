#!/usr/bin/env bash
# 迁移门禁的本地等价检查（CI 中由 .github/workflows/ci.yml 的 migrations job 执行）。
# 需要一个可写的 PostgreSQL 实例；默认连接与 .env.example 一致。
#   DATABASE_URL=... SHADOW_DATABASE_URL=... apps/api/scripts/check-migrations.sh
# 成功退出码 0；迁移缺失、SQL 不可重放或存在漂移时非 0。
set -euo pipefail

cd "$(dirname "$0")/../.."

DATABASE_URL="${DATABASE_URL:-postgresql://practice:practice@localhost:5432/practice?schema=public}"
SHADOW_DATABASE_URL="${SHADOW_DATABASE_URL:-postgresql://practice:practice@localhost:5432/practice_shadow?schema=public}"
export DATABASE_URL SHADOW_DATABASE_URL

echo "▶ 校验迁移锁 provider"
grep -Eq '^provider[[:space:]]*=[[:space:]]*"postgresql"$' \
  apps/api/prisma/migrations/migration_lock.toml

echo "▶ 校验 Prisma schema"
npm exec --workspace=@practice/api -- prisma validate

echo "▶ 生成 Prisma Client"
npm run db:generate -w @practice/api

echo "▶ 在数据库上重放全部迁移"
npm run db:deploy -w @practice/api

echo "▶ 校验迁移状态"
npm run db:status

echo "▶ 漂移检测：迁移历史必须与 schema.prisma 一致"
npm exec --workspace=@practice/api -- prisma migrate diff \
  --from-url "$DATABASE_URL" \
  --to-schema-datamodel apps/api/prisma/schema.prisma \
  --shadow-database-url "$SHADOW_DATABASE_URL" \
  --exit-code

echo "✅ 迁移检查通过：无缺失迁移、无漂移"
