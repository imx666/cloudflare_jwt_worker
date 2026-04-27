/**
 * Cloudflare Auth Worker
 *
 * 功能：
 * 1. 验证 JWT Token（ES256 公钥验证）
 * 2. 路由分发到后端微服务
 * 3. 透传请求和响应
 */
import { jwtVerify, JWTPayload, importSPKI } from 'jose';

// Worker 版本号，每次部署前递增
const WORKER_VERSION = 'v1.3';

export interface Env {
  // JWT 公钥（PEM 格式），用于验证 RS256/ES256 签名
  // 后端持有私钥签发 JWT，Workers 只存公钥验证
  JWT_PUBLIC_KEY: string;

  // 后端微服务地址
  UPSTREAM_USER_SERVICE: string;
  UPSTREAM_ORDER_SERVICE: string;
  UPSTREAM_PRODUCT_SERVICE: string;
  UPSTREAM_AUTH_SERVICE: string;
}

interface CustomJWTPayload extends JWTPayload {
  sub?: string;  // user_id
}

// 缓存解析后的公钥，避免每次请求都重新解析
let cachedPublicKey: CryptoKey | null = null;

/**
 * 解析并缓存公钥
 */
async function getPublicKey(publicKeyPem: string): Promise<CryptoKey> {
  if (cachedPublicKey) {
    return cachedPublicKey;
  }
  cachedPublicKey = await importSPKI(publicKeyPem, 'ES256');
  return cachedPublicKey;
}

/**
 * 验证 JWT Token（公钥验证，无需知道私钥）
 */
async function verifyToken(token: string, publicKey: CryptoKey): Promise<CustomJWTPayload> {
  const { payload } = await jwtVerify(token, publicKey, {
    algorithms: ['ES256'],
  });
  return payload as CustomJWTPayload;
}

/**
 * 从请求头获取 Bearer Token
 */
function extractToken(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return null;
  }
  return authHeader.substring(7).trim();
}

/**
 * 构造错误响应
 */
function errorResponse(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * 转发请求到上游服务
 * @param upstreamBaseUrl 上游服务基础地址
 * @param request 原始请求
 * @param overridePath 可选，覆盖请求路径（用于路径重写场景）
 */
async function proxyToUpstream(
  upstreamBaseUrl: string,
  request: Request,
  overridePath?: string
): Promise<Response> {
  const url = new URL(request.url);
  const upstreamPath = overridePath ?? url.pathname;
  const upstreamUrl = `${upstreamBaseUrl}${upstreamPath}${url.search}`;

  // 克隆请求以安全读取 body
  const reqClone = request.clone();
  const body = await reqClone.text();

  const upstreamResponse = await fetch(upstreamUrl, {
    method: request.method,
    headers: request.headers,
    body: body || undefined,
  });

  return new Response(upstreamResponse.body, {
    status: upstreamResponse.status,
    headers: upstreamResponse.headers,
  });
}

/**
 * 主入口
 */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // ============================================
    // 公开路由（无需认证）
    // ============================================
    if (url.pathname === '/health' || url.pathname === '/ping') {
      return new Response(JSON.stringify({ status: 'ok', version: WORKER_VERSION }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // ============================================
    // JWT 认证
    // ============================================
    const authHeader = request.headers.get('Authorization');
    const token = extractToken(authHeader);

    if (!token) {
      return errorResponse('Unauthorized: Missing token', 401);
    }

    let payload: CustomJWTPayload;
    try {
      const publicKey = await getPublicKey(env.JWT_PUBLIC_KEY);
      payload = await verifyToken(token, publicKey);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Invalid token';
      return errorResponse(`Unauthorized: ${message}`, 401);
    }

    // 验证 payload 中有 sub 字段
    if (!payload.sub) {
      return errorResponse('Unauthorized: Invalid token payload', 401);
    }

    // 计算 token 剩余有效时间（秒）
    const now = Math.floor(Date.now() / 1000);
    const expiresIn = payload.exp ? Math.max(0, payload.exp - now) : null;

    // ============================================
    // 路由分发
    // ============================================
    const path = url.pathname;

    if (path === '/api/v1/token-info') {
      // 特殊测试接口：返回 token 信息和剩余过期时间
      return new Response(JSON.stringify({
        version: WORKER_VERSION,
        user_id: payload.sub,
        issued_at: payload.iat,
        expires_at: payload.exp,
        expires_in: expiresIn,
        token_valid: true,
      }), {
        headers: { 'Content-Type': 'application/json' },
      });

    } else if (path.startsWith('/api/v1/users')) {
      // 用户服务
      return proxyToUpstream(env.UPSTREAM_USER_SERVICE, request);

    } else if (path.startsWith('/api/v1/orders')) {
      // 订单服务
      return proxyToUpstream(env.UPSTREAM_ORDER_SERVICE, request);

    } else if (path.startsWith('/api/v1/products')) {
      // 商品服务
      return proxyToUpstream(env.UPSTREAM_PRODUCT_SERVICE, request);

    } else if (path.startsWith('/auth/')) {
      // Auth 代理路由：去掉 /auth 前缀后转发到上游
      // 例如 /auth/beekeeper/visors/9001/status -> /beekeeper/visors/9001/status
      const upstreamPath = path.replace('/auth', '');
      const authService = env.UPSTREAM_AUTH_SERVICE || env.UPSTREAM_USER_SERVICE || 'http://volefuture.com';
      return proxyToUpstream(authService, request, upstreamPath);

    } else if (path === '/version') {
      // 版本号查询接口（无需认证）
      return new Response(JSON.stringify({
        version: WORKER_VERSION,
        status: 'ok',
      }), {
        headers: { 'Content-Type': 'application/json' },
      });

    } else {
      // 未匹配的路由
      return errorResponse('Not Found', 404);
    }
  },
};
