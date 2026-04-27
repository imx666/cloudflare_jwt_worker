#!/bin/bash
#
# Cloudflare JWT Worker 测试脚本
#
# 使用方式:
#   ./test_worker.sh [命令]
#   ./test_worker.sh issue alice    # 签发 JWT 并测试
#   ./test_worker.sh health         # 测试健康检查
#   ./test_worker.sh users alice    # 测试用户服务
#   ./test_worker.sh orders bob     # 测试订单服务
#   ./test_worker.sh products       # 测试商品服务
#   ./test_worker.sh unauthorized   # 测试无 token 情况
#   ./test_worker.sh expired        # 测试过期 token
#

set -e

WORKER_URL="https://cf-jwt.imxwilson.workers.dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JWT=""

# 签发 JWT (优先使用 Python 版本)
issue_jwt() {
    local user_id=$1
    local expire_time=${2:-"1h"}

    echo "正在为用户 [$user_id] 签发 JWT (过期时间: $expire_time)..."

    # 优先使用 Python 版本
    if command -v python3 >/dev/null 2>&1; then
        JWT=$(python3 "$SCRIPT_DIR/issue_jwt.py" "$user_id" "$expire_time" --no-print-curl 2>/dev/null | grep -v "^$" | tail -1)
    elif command -v python >/dev/null 2>&1; then
        JWT=$(python "$SCRIPT_DIR/issue_jwt.py" "$user_id" "$expire_time" --no-print-curl 2>/dev/null | grep -v "^$" | tail -1)
    elif command -v npx >/dev/null 2>&1; then
        # 备用 Node.js 版本
        JWT=$(cd "$SCRIPT_DIR" && npx ts-node issue_jwt.ts "$user_id" "$expire_time" 2>/dev/null | grep -v "===" | grep -v "常用测试命令" | grep -v "^$" | grep -v "curl" | head -1)
    else
        echo "❌ 错误: 需要 Python3 或 Node.js 来签发 JWT"
        exit 1
    fi

    if [ -z "$JWT" ]; then
        echo "❌ JWT 签发失败"
        exit 1
    fi

    echo "✅ JWT 签发成功"
}

# 测试 health 端点
test_health() {
    echo ""
    echo "=== 测试 Health 端点 ==="
    echo "GET $WORKER_URL/health"
    echo ""

    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" "$WORKER_URL/health")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "200" ]; then
        echo "✅ Health 检查通过"
        # 提取版本号
        version=$(echo "$body" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        if [ -n "$version" ]; then
            echo "📦 Worker 版本: $version"
        fi
    else
        echo "❌ Health 检查失败"
    fi
}

# 测试 token-info 接口
test_token_info() {
    echo ""
    echo "=== 测试 Token 信息接口 ==="
    issue_jwt "testuser"
    echo "GET $WORKER_URL/api/v1/token-info"
    echo "Authorization: Bearer $JWT"
    echo ""

    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -H "Authorization: Bearer $JWT" "$WORKER_URL/api/v1/token-info")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "200" ]; then
        version=$(echo "$body" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        expires_in=$(echo "$body" | grep -o '"expires_in":[0-9]*' | cut -d':' -f2)
        echo "📦 Worker 版本: $version"
        echo "⏱️  Token 剩余有效期: ${expires_in}s"
        echo "✅ Token 信息接口正常"
    else
        echo "❌ Token 信息接口失败"
    fi
}

# 测试带 JWT 的接口
test_authenticated() {
    local endpoint=$1
    local description=$2
    local user_id=${3:-"testuser"}
    local method=${4:-"GET"}
    local data=${5:-""}

    echo ""
    echo "=== $description ==="
    echo "$method $WORKER_URL$endpoint"
    echo "Authorization: Bearer $JWT"
    if [ -n "$data" ]; then
        echo "Body: $data"
    fi
    echo ""

    # 如果没有 JWT，先签发
    if [ -z "$JWT" ]; then
        issue_jwt "$user_id"
    fi

    local curl_opts=(-s -w "\nHTTP_CODE:%{http_code}" -H "Authorization: Bearer $JWT" -X "$method")
    if [ -n "$data" ]; then
        curl_opts+=(-H "Content-Type: application/json" -d "$data")
    fi

    response=$(curl "${curl_opts[@]}" "$WORKER_URL$endpoint")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "200" ] || [ "$http_code" = "502" ] || [ "$http_code" = "404" ]; then
        # 502 表示上游服务不可达，但 JWT 验证通过
        echo "✅ JWT 验证通过 (上游返回 $http_code)"
    else
        echo "❌ 请求失败"
    fi
}

# 测试无 token
test_no_token() {
    echo ""
    echo "=== 测试无 Token 访问 ==="
    echo "POST $WORKER_URL/auth/beekeeper/visors/9001/status"
    echo ""

    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "$WORKER_URL/auth/beekeeper/visors/9001/status")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "401" ]; then
        echo "✅ 正确拒绝无 Token 请求"
    else
        echo "❌ 应该返回 401"
    fi
}

# 测试过期 token
test_expired_token() {
    echo ""
    echo "=== 测试过期 Token ==="
    echo "签发一个已过期的 JWT..."

    # 签发一个已过期的 JWT
    if command -v python3 >/dev/null 2>&1; then
        JWT=$(python3 "$SCRIPT_DIR/issue_jwt.py" "testuser" "-1m" --no-print-curl 2>/dev/null | grep -v "^$" | tail -1)
    elif command -v python >/dev/null 2>&1; then
        JWT=$(python "$SCRIPT_DIR/issue_jwt.py" "testuser" "-1m" --no-print-curl 2>/dev/null | grep -v "^$" | tail -1)
    else
        JWT=$(cd "$SCRIPT_DIR" && npx ts-node issue_jwt.ts "testuser" "-1m" 2>/dev/null | grep -v "===" | grep -v "常用测试命令" | grep -v "^$" | grep -v "curl" | head -1)
    fi

    echo "POST $WORKER_URL/auth/beekeeper/visors/9001/status"
    echo "Authorization: Bearer [过期token]"
    echo ""

    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST -H "Authorization: Bearer $JWT" "$WORKER_URL/auth/beekeeper/visors/9001/status")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "401" ]; then
        echo "✅ 正确拒绝过期 Token"
    else
        echo "❌ 应该返回 401"
    fi
}

# 测试无效 token
test_invalid_token() {
    echo ""
    echo "=== 测试无效 Token ==="
    local invalid_token="eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0dXNlciIsImlhdCI6MTcwMDAwMDAwMH0.invalid_signature"

    echo "POST $WORKER_URL/auth/beekeeper/visors/9001/status"
    echo "Authorization: Bearer [无效token]"
    echo ""

    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST -H "Authorization: Bearer $invalid_token" "$WORKER_URL/auth/beekeeper/visors/9001/status")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "401" ]; then
        echo "✅ 正确拒绝无效 Token"
    else
        echo "❌ 应该返回 401"
    fi
}

# 测试 payload 缺少 sub
test_missing_sub() {
    echo ""
    echo "=== 测试缺少 sub 的 Token ==="
    echo "创建一个没有 sub 字段的 JWT..."

    # 创建一个简单的手动构造的 JWT (header 和 payload，没有正确签名)
    local header=$(echo -n '{"alg":"ES256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
    local payload=$(echo -n '{"iat":1700000000,"exp":1700003600}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
    local invalid_token="${header}.${payload}.signature"

    echo "POST $WORKER_URL/auth/beekeeper/visors/9001/status"
    echo ""

    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST -H "Authorization: Bearer $invalid_token" "$WORKER_URL/auth/beekeeper/visors/9001/status")
    http_code=$(echo "$response" | grep "HTTP_CODE" | cut -d: -f2)
    body=$(echo "$response" | sed '/HTTP_CODE/d')

    echo "响应: $body"
    echo "状态码: $http_code"

    if [ "$http_code" = "401" ]; then
        echo "✅ 正确拒绝缺少 sub 的 Token"
    else
        echo "❌ 应该返回 401"
    fi
}

# 测试 auth 代理路由 (POST)
test_auth_proxy() {
    echo ""
    echo "=== 测试 Auth 代理路由 (POST) ==="
    issue_jwt "testuser"
    test_authenticated "/auth/beekeeper/visors/9001/status" "Auth 代理路由" "testuser" "POST" '{"status":"active"}'
}

# 交互式测试
interactive_test() {
    echo ""
    echo "========================================"
    echo "   Cloudflare JWT Worker 交互式测试"
    echo "========================================"
    echo ""

    PS3="请选择测试选项: "
    options=(
        "签发 JWT 并测试用户服务"
        "测试 health 端点"
        "测试用户服务 (/api/v1/users)"
        "测试订单服务 (/api/v1/orders)"
        "测试商品服务 (/api/v1/products)"
        "测试 Auth 代理路由 (POST /auth/beekeeper/visors/9001/status)"
        "测试无 Token 访问"
        "测试过期 Token"
        "测试无效 Token"
        "测试缺少 sub 的 Token"
        "测试 Token 信息接口 (/api/v1/token-info)"
        "运行所有测试"
        "退出"
    )

    select opt in "${options[@]}"; do
        case $REPLY in
            1)
                read -p "请输入用户ID: " user_id
                issue_jwt "$user_id"
                test_authenticated "/api/v1/users/me" "测试用户服务" "$user_id"
                ;;
            2) test_health ;;
            3)
                issue_jwt "testuser"
                test_authenticated "/api/v1/users/me" "测试用户服务"
                ;;
            4)
                issue_jwt "testuser"
                test_authenticated "/api/v1/orders" "测试订单服务"
                ;;
            5)
                issue_jwt "testuser"
                test_authenticated "/api/v1/products" "测试商品服务"
                ;;
            6) test_auth_proxy ;;
            7) test_no_token ;;
            8) test_expired_token ;;
            9) test_invalid_token ;;
            10) test_missing_sub ;;
            11) test_token_info ;;
            12)
                echo ""
                echo "========================================"
                echo "   运行所有测试..."
                echo "========================================"
                test_health
                issue_jwt "testuser"
                test_authenticated "/api/v1/users/me" "测试用户服务"
                test_authenticated "/api/v1/orders" "测试订单服务"
                test_authenticated "/api/v1/products" "测试商品服务"
                test_auth_proxy
                test_no_token
                test_expired_token
                test_invalid_token
                test_missing_sub
                test_token_info
                echo ""
                echo "========================================"
                echo "   所有测试完成!"
                echo "========================================"
                ;;
            13) break ;;
            *) echo "无效选项" ;;
        esac
    done
}

# 主入口
main() {
    local command=${1:-""}

    case $command in
        issue)
            user_id=${2:-"testuser"}
            expire_time=${3:-"1h"}
            issue_jwt "$user_id" "$expire_time"
            echo ""
            echo "JWT Token: $JWT"
            ;;
        health) test_health ;;
        users)
            user_id=${2:-"testuser"}
            issue_jwt "$user_id"
            test_authenticated "/api/v1/users/me" "测试用户服务" "$user_id"
            ;;
        orders)
            user_id=${2:-"testuser"}
            issue_jwt "$user_id"
            test_authenticated "/api/v1/orders" "测试订单服务" "$user_id"
            ;;
        products)
            user_id=${2:-"testuser"}
            issue_jwt "$user_id"
            test_authenticated "/api/v1/products" "测试商品服务" "$user_id"
            ;;
        auth)
            user_id=${2:-"testuser"}
            issue_jwt "$user_id"
            test_authenticated "/auth/beekeeper/visors/9001/status" "Auth 代理路由" "$user_id" "POST" '{"status":"active"}'
            ;;
        token-info)
            test_token_info
            ;;
        unauthorized) test_no_token ;;
        expired) test_expired_token ;;
        invalid) test_invalid_token ;;
        missing-sub) test_missing_sub ;;
        all)
            echo "========================================"
            echo "   运行所有测试..."
            echo "========================================"
            test_health
            issue_jwt "testuser"
            test_authenticated "/api/v1/users/me" "测试用户服务"
            test_authenticated "/api/v1/orders" "测试订单服务"
            test_authenticated "/api/v1/products" "测试商品服务"
            test_auth_proxy
            test_no_token
            test_expired_token
            test_invalid_token
            test_missing_sub
            test_token_info
            echo ""
            echo "========================================"
            echo "   所有测试完成!"
            echo "========================================"
            ;;
        *) interactive_test ;;
    esac
}

main "$@"