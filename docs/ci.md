# 持续集成门禁

工作流：`.github/workflows/ci.yml`（在 PR 与 `main`/`v*` tag 推送时运行）。

## 门禁组成

| Job | 作用 | 关键命令 |
|---|---|---|
| `lockfile` 依赖锁定 | 禁止未锁定/与清单不同步的依赖进入流水线 | `npm ci`（不同步即失败）、`npm ls --workspaces` |
| `migrations` 迁移检查 | 迁移 SQL 可重放、无漂移、无未应用迁移 | `prisma validate` → `migrate deploy`（PostgreSQL 16 服务容器）→ `migrate status` → `migrate diff --exit-code` |
| `typecheck` 类型检查 | 四个工作区全量 TS/Vue 类型检查 | `npm run typecheck`（pre 钩子先构建 contracts） |
| `test` 单元测试 | contracts / api / web / worker 单测 | `prisma generate` 后 `npm run test` |
| `web-build` 前端构建 | 验证可发布的生产构建 | 构建 contracts 后 `npm run build -w @practice/web`，产物必须存在 |

全部使用 Node.js 22（见 `package.json` engines），原生依赖（argon2）在该版本有预编译二进制。

## 缓存隔离

- 每个 job 独立 checkout、独立执行 `npm ci`，不跨 job 复用 `node_modules` 或构建产物。
- npm 下载缓存路径 `~/.npm` 的键为
  `npm-<github.job>-ubuntu-node22-<package-lock.json 哈希>`，
  job 名是键的一部分，不同 job 即使在同一 runner 命中缓存，恢复的也只是下载缓存而非安装结果，安装过程始终从锁文件全新执行。
- 迁移检查使用一次性 PostgreSQL 服务容器，运行结束即销毁；不依赖任何外部共享数据库。

## 失败不得发布

- `release` job 通过 `needs: [lockfile, migrations, typecheck, test, web-build]` 强依赖全部五个门禁，任一失败则整体跳过，不创建 GitHub Release、不上传发布物。
- `release` 仅在推送 `v*` tag 时执行，并校验 tag 与 `package.json#version` 一致；发布物来自 release job 自己干净工作区的全量 `npm run build`，而非其他 job 的中间产物。
- 要求在 GitHub 仓库 Settings → Branches → Branch protection rules 中为 `main` 勾选：
  - Require status checks to pass before merging，并将 `门禁 · 依赖锁定`、`门禁 · 数据库迁移`、`门禁 · 类型检查`、`门禁 · 单元测试`、`门禁 · 前端构建` 全部设为必需检查；
  - Require branches to be up to date before merging；
  - 对受保护环境（如 production）在 Settings → Environments 中要求 `发布 · 全部门禁通过后打包` 通过后才可部署。

## 迁移检查的本地等价命令

CI 的迁移门禁逻辑封装在 `apps/api/scripts/check-migrations.sh`，本地对同一个 PostgreSQL 实例准备好主库与影子库后即可运行（与 CI 完全一致）：

```bash
createdb practice && createdb practice_shadow
apps/api/scripts/check-migrations.sh
# 或显式指定连接：
DATABASE_URL="postgresql://ci:ci@localhost:5432/ci?schema=public" \
SHADOW_DATABASE_URL="postgresql://ci:ci@localhost:5432/ci_shadow?schema=public" \
  apps/api/scripts/check-migrations.sh
```

脚本依次执行：迁移锁 provider 校验 → `prisma validate` → `prisma generate` → `prisma migrate deploy` → `prisma migrate status` → `prisma migrate diff --exit-code`。

`migrate diff` 无差异时退出码为 0 且无输出；存在漂移时退出码为 2，此时应在本地执行 `npm run db:migrate` 生成并提交迁移后再推送。

> 端到端测试（Playwright）依赖完整的 PostgreSQL、Redis、S3/MinIO、FFmpeg 与运行中的应用，不纳入门禁；按 README 在预发布环境手动或由独立工作流运行。
