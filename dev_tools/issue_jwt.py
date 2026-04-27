#!/usr/bin/env python3
"""
JWT 签发工具 (Python 版本)
使用私钥签发 ES256 JWT Token，用于测试 Cloudflare Worker

依赖安装:
    pip install cryptography PyJWT

使用方式:
    python issue_jwt.py <user_id> [过期时间]
    python issue_jwt.py alice
    python issue_jwt.py bob 2h
"""

import sys
import json
import time
import base64
import hashlib
import argparse
from datetime import datetime, timedelta
from pathlib import Path

try:
    import jwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.backends import default_backend
except ImportError:
    print("错误: 缺少依赖，请先安装:")
    print("  pip install cryptography PyJWT")
    sys.exit(1)


WORKER_URL = "https://cf-jwt.imxwilson.workers.dev"
SCRIPT_DIR = Path(__file__).parent
PRIVATE_KEY_PATH = SCRIPT_DIR.parent / "private.pem"


def load_private_key():
    """加载 EC 私钥"""
    with open(PRIVATE_KEY_PATH, "rb") as f:
        return f.read()


def parse_expiration(exp_str: str) -> int:
    """解析过期时间字符串，返回秒数"""
    if not exp_str:
        return 3600  # 默认 1 小时

    unit = exp_str[-1]
    value = int(exp_str[:-1])

    if unit == "h":
        return value * 3600
    elif unit == "d":
        return value * 86400
    elif unit == "m":
        return value * 60
    else:
        raise ValueError(f"无效的时间单位: {unit}，支持 h(小时), d(天), m(分钟)")


def issue_jwt(user_id: str, expiration_time: str = "1h") -> str:
    """签发 JWT Token"""
    private_key = load_private_key()

    now = int(time.time())
    exp = now + parse_expiration(expiration_time)

    payload = {
        "sub": user_id,
        "iat": now,
        "exp": exp,
    }

    # 使用 ES256 (ECDSA with P-256 and SHA-256)
    token = jwt.encode(
        payload,
        private_key,
        algorithm="ES256",
        headers={"typ": "JWT", "alg": "ES256"}
    )

    return token


def main():
    parser = argparse.ArgumentParser(description="JWT 签发工具")
    parser.add_argument("user_id", nargs="?", help="用户ID")
    parser.add_argument("expiration", nargs="?", default="1h", help="过期时间，如 1h, 2h, 7d")
    parser.add_argument("--no-print-curl", action="store_true", help="只输出 JWT，不输出 curl 命令")

    args = parser.parse_args()

    if not args.user_id:
        print(__doc__)
        sys.exit(1)

    try:
        token = issue_jwt(args.user_id, args.expiration)

        print("\n=== JWT Token ===")
        print(token)

        if not args.no_print_curl:
            print("\n=== 常用测试命令 ===")
            print(f"\n# Health 检查 (无需认证):")
            print(f"curl {WORKER_URL}/health")
            print(f"\n# 测试用户服务:")
            print(f"curl -H \"Authorization: Bearer {token}\" {WORKER_URL}/api/v1/users/me")
            print(f"\n# 测试订单服务:")
            print(f"curl -H \"Authorization: Bearer {token}\" {WORKER_URL}/api/v1/orders")
            print(f"\n# 测试商品服务:")
            print(f"curl -H \"Authorization: Bearer {token}\" {WORKER_URL}/api/v1/products")
            print(f"\n# 测试 Auth 代理路由 (POST):")
            print(f"curl -X POST -H \"Authorization: Bearer {token}\" -H \"Content-Type: application/json\" -d '{{\"status\":\"active\"}}' {WORKER_URL}/auth/beekeeper/visors/9001/status")

    except Exception as e:
        print(f"签发 JWT 失败: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
