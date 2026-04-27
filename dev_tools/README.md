# Dev Tools

用于测试 Cloudflare JWT Worker 的开发工具。

## 目录结构

```
dev_tools/
├── issue_jwt.ts    # JWT 签发工具
├── test_worker.sh  # Worker 测试脚本
└── README.md        # 本文档
```

## 准备

**Python 版本（推荐）:**
```bash
pip install cryptography PyJWT
```

**Node.js 版本:**
```bash
npm install
```

## 使用方法

### 1. 签发 JWT Token

**Python 版本（推荐）:**
```bash
python dev_tools/issue_jwt.py <user_id> [过期时间]
```

**Node.js 版本:**
```bash
npx ts-node dev_tools/issue_jwt.ts <user_id> [过期时间]
```

**参数说明：**
- `user_id`: 用户ID（必填）
- `过期时间`: 格式 `1h`, `2h`, `7d`, `30m`（可选，默认 1h）

**示例：**

```bash
# 为用户 alice 签发 1 小时有效的 JWT
npx ts-node dev_tools/issue_jwt.ts alice

# 为用户 bob 签发 2 小时有效的 JWT
npx ts-node dev_tools/issue_jwt.ts bob 2h

# 为用户 charlie 签发 7 天有效的 JWT
npx ts-node dev_tools/issue_jwt.ts charlie 7d
```

签发后会输出常用测试命令，可以直接复制使用。

### 2. 测试 Worker

#### 交互式测试

直接运行脚本进入交互模式：

```bash
./dev_tools/test_worker.sh
```

#### 命令行测试

```bash
# 测试 health 端点
./dev_tools/test_worker.sh health

# 签发 JWT 并测试用户服务
./dev_tools/test_worker.sh issue alice
./dev_tools/test_worker.sh users alice

# 测试各服务
./dev_tools/test_worker.sh users          # 默认用户 testuser
./dev_tools/test_worker.sh orders bob
./dev_tools/test_worker.sh products charlie

# 测试错误情况
./dev_tools/test_worker.sh unauthorized   # 测试无 token
./dev_tools/test_worker.sh expired         # 测试过期 token
./dev_tools/test_worker.sh invalid         # 测试无效签名
./dev_tools/test_worker.sh missing-sub     # 测试缺少 sub 字段

# 运行所有测试
./dev_tools/test_worker.sh all
```

### 3. 常用 curl 命令

```bash
WORKER_URL="https://cf-jwt.imxwilson.workers.dev"

# Health 检查（无需认证）
curl $WORKER_URL/health

# 带 JWT 访问用户服务
curl -H "Authorization: Bearer <your_jwt_token>" $WORKER_URL/api/v1/users/me

# 带 JWT 访问订单服务
curl -H "Authorization: Bearer <your_jwt_token>" $WORKER_URL/api/v1/orders

# 带 JWT 访问商品服务
curl -H "Authorization: Bearer <your_jwt_token>" $WORKER_URL/api/v1/products

# 测试无 token（应该返回 401）
curl $WORKER_URL/api/v1/users/me

# 测试过期 token（应该返回 401）
curl -H "Authorization: Bearer <expired_token>" $WORKER_URL/api/v1/users/me
```

## 测试用例说明

| 测试用例 | 说明 | 预期结果 |
|---------|------|---------|
| `health` | 测试健康检查端点 | 200 OK |
| `users` | 测试用户服务路由 | 200/502 (JWT验证通过) |
| `orders` | 测试订单服务路由 | 200/502 (JWT验证通过) |
| `products` | 测试商品服务路由 | 200/502 (JWT验证通过) |
| `unauthorized` | 无 Authorization 头 | 401 Unauthorized |
| `expired` | 使用已过期的 JWT | 401 Token expired |
| `invalid` | 使用伪造签名的 JWT | 401 Invalid signature |
| `missing-sub` | JWT payload 缺少 sub 字段 | 401 Invalid payload |

## Worker API 端点

| 端点 | 方法 | 认证 | 说明 |
|------|------|------|------|
| `/health` | GET | 无 | 健康检查 |
| `/ping` | GET | 无 | 健康检查 |
| `/api/v1/users/*` | ANY | JWT | 路由到用户服务 |
| `/api/v1/orders/*` | ANY | JWT | 路由到订单服务 |
| `/api/v1/products/*` | ANY | JWT | 路由到商品服务 |

## JWT 要求

- 算法：ES256
- 必须包含 `sub` 字段（用户ID）
- 必须包含 `iat` (签发时间) 和 `exp` (过期时间)
- 使用项目私钥 `../private.pem` 签发