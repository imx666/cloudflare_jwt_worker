#!/usr/bin/env node
/**
 * JWT 签发工具
 * 使用私钥签发 ES256 JWT Token，用于测试 Cloudflare Worker
 *
 * 使用方式:
 *   npx ts-node issue_jwt.ts [user_id]
 *   npx ts-node issue_jwt.ts alice
 */

import { SignJWT, importPKCS8 } from 'jose';
import * as fs from 'fs';
import * as path from 'path';

const PRIVATE_KEY_PATH = path.resolve(__dirname, '../private.pem');
const WORKER_URL = 'https://cf-jwt.imxwilson.workers.dev';

interface JWTOptions {
  userId: string;
  expirationTime?: string;  // 如 '1h', '2h', '7d'
  issuedAt?: number;
}

async function loadPrivateKey(): Promise<string> {
  return fs.readFileSync(PRIVATE_KEY_PATH, 'utf-8');
}

async function issueJWT(options: JWTOptions): Promise<string> {
  const privateKeyPem = await loadPrivateKey();
  const privateKey = await importPKCS8(privateKeyPem, 'ES256');

  const now = Math.floor(Date.now() / 1000);
  const jwtOptions: any = {
    alg: 'ES256',
    typ: 'JWT',
    iat: options.issuedAt || now,
  };

  // 设置过期时间
  if (options.expirationTime) {
    const match = options.expirationTime.match(/^(\d+)(h|d|m)$/);
    if (match) {
      const value = parseInt(match[1]);
      const unit = match[2];
      const exp = unit === 'h' ? value * 3600 : unit === 'd' ? value * 86400 : value * 60;
      jwtOptions.exp = now + exp;
    }
  } else {
    // 默认 1 小时
    jwtOptions.exp = now + 3600;
  }

  const jwt = await new SignJWT({ sub: options.userId })
    .setProtectedHeader({ alg: 'ES256', typ: 'JWT' })
    .setIssuedAt(jwtOptions.iat)
    .setExpirationTime(jwtOptions.exp)
    .setSubject(options.userId)
    .sign(privateKey);

  return jwt;
}

function printUsage() {
  console.log(`
用法: npx ts-node issue_jwt.ts <user_id> [过期时间]

参数:
  user_id      用户ID (必填)
  过期时间     格式: 1h, 2h, 7d, 30m (可选, 默认 1h)

示例:
  npx ts-node issue_jwt.ts alice
  npx ts-node issue_jwt.ts bob 2h
  npx ts-node issue_jwt.ts charlie 7d
  `);
}

async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    printUsage();
    process.exit(1);
  }

  const userId = args[0];
  const expirationTime = args[1] || '1h';

  try {
    const token = await issueJWT({ userId, expirationTime });
    console.log('\n=== JWT Token ===');
    console.log(token);
    console.log('\n=== 常用测试命令 ===');
    console.log(`\n# 测试 health 端点 (无需认证):`);
    console.log(`curl ${WORKER_URL}/health`);
    console.log(`\n# 测试用户服务 (带 JWT):`);
    console.log(`curl -H "Authorization: Bearer ${token}" ${WORKER_URL}/api/v1/users/me`);
    console.log(`\n# 测试订单服务 (带 JWT):`);
    console.log(`curl -H "Authorization: Bearer ${token}" ${WORKER_URL}/api/v1/orders`);
    console.log(`\n# 测试带失效 token (过期 1 分钟前):`);
    const expiredToken = await issueJWT({ userId, expirationTime: '-1m' });
    console.log(`curl -H "Authorization: Bearer ${expiredToken}" ${WORKER_URL}/api/v1/users/me`);
  } catch (error) {
    console.error('签发 JWT 失败:', error);
    process.exit(1);
  }
}

main();