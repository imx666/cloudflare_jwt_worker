# Cloudflare Auth Worker

基于 Cloudflare Workers 的 JWT 认证与 API 路由网关。

## 架构

```
                    ┌─────────────────┐
                    │   后端服务       │
                    │  (持有私钥)      │
                    └────────┬────────┘
                             │ 签发 JWT (ES256)
                             ▼
┌────────┐   请求 JWT   ┌─────────────┐   验证通过   ┌─────────────────┐
│ 客户端 │ ──────────▶ │ Cloudflare  │ ──────────▶ │   后端微服务     │
└────────┘             │   Worker    │             │ (处理业务逻辑)   │
                       │  (仅存公钥)  │             └─────────────────┘
                       └─────────────┘
```

**优势**：Workers 只存公钥，无法签发 JWT；私钥只留在后端，安全性更高。

## 功能

- ✅ JWT Token 验证（**ES256 公钥验证**）
- ✅ 路由分发到后端微服务
- ✅ 透传请求/响应
- ✅ 健康检查端点（无需认证）

## 密钥生成

### 1. 生成 ES256 密钥对

```bash
# 生成私钥
openssl ecparam -name prime256v1 -genkey -noout -out private.pem

# 导出公钥
openssl ec -in private.pem -pubout -out public.pem

# 查看公钥（复制到 wrangler.toml）
cat public.pem
```

### 2. 配置 Workers（公钥）

编辑 `wrangler.toml`，把公钥填入：

```toml
[vars]
JWT_PUBLIC_KEY = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...\n-----END PUBLIC KEY-----"
```

### 3. 后端配置（私钥）

后端持有私钥，用于签发 JWT。参考下面的后端示例。

## 快速开始

### 1. 安装依赖

```bash
cd cloudflare_auth_worker
npm install
```

### 2. 配置

编辑 `wrangler.toml`：

```toml
[vars]
JWT_PUBLIC_KEY = "-----BEGIN PUBLIC KEY-----\n你的公钥内容\n-----END PUBLIC KEY-----"

UPSTREAM_USER_SERVICE = "http://user-service.internal"
UPSTREAM_ORDER_SERVICE = "http://order-service.internal"
UPSTREAM_PRODUCT_SERVICE = "http://product-service.internal"
```

### 3. 本地开发

```bash
npm run dev
```

### 4. 部署

```bash
npm run deploy
```

## API 路由

| 路径 | 后端服务 | 说明 |
|------|----------|------|
| `/api/v1/users/*` | UPSTREAM_USER_SERVICE | 用户服务 |
| `/api/v1/orders/*` | UPSTREAM_ORDER_SERVICE | 订单服务 |
| `/api/v1/products/*` | UPSTREAM_PRODUCT_SERVICE | 商品服务 |
| `/health` | - | 健康检查（无需认证） |

## 请求示例

```bash
# 带 JWT 的请求
curl -X GET https://your-worker.example.com/api/v1/users/123 \
  -H "Authorization: Bearer eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9..."

# 健康检查
curl https://your-worker.example.com/health
```

## 环境变量

| 变量 | 说明 | 必填 |
|------|------|------|
| `JWT_PUBLIC_KEY` | JWT 公钥（PEM 格式），用于验证 ES256 签名 | ✅ |
| `UPSTREAM_USER_SERVICE` | 用户服务地址 | ✅ |
| `UPSTREAM_ORDER_SERVICE` | 订单服务地址 | ✅ |
| `UPSTREAM_PRODUCT_SERVICE` | 商品服务地址 | ✅ |

## 后端签发 JWT 示例（Python）

```python
from jose import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
import time

# 加载私钥
with open("private.pem", "rb") as f:
    private_key = serialization.load_pem_private_key(f.read(), password=None)

# 签发 JWT
payload = {
    "sub": "user_id_123",      # user_id
    "iat": int(time.time()),   # 签发时间
    "exp": int(time.time()) + 86400 * 7  # 7 天过期
}

token = jwt.encode(
    payload,
    private_key,
    algorithm="ES256"
)
print(token)
```

## 安全优势

| 对比 | HS256（共享密钥） | ES256（公钥验证） |
|------|-------------------|-------------------|
| Workers 需要 | 知道密钥 | 只需公钥 |
| 私钥泄露风险 | Workers 泄露 = 私钥泄露 | Workers 泄露公钥不影响 |
| 后端改动 | 无 | 需改用私钥签发 |
