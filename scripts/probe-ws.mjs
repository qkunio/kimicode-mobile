#!/usr/bin/env node
/**
 * RC WebSocket 鉴权探测。
 *
 * 验证 wss://code-rc.kimi.com/devices/<id>/api/v1/ws 这一跳接受哪种凭证：
 *   A) Authorization: Bearer <refresh_token>            (原生客户端首选)
 *   B) subprotocol  kimi-code.bearer.<refresh_token>    (浏览器只能用这个)
 *   C) 无凭证                                            (对照组，应当失败)
 *
 * 成功判定：收到 server_hello。随后脚本会补一次 client_hello，
 * 确认 ack 能正常返回（即握手全程可用，而不只是 TCP 通了）。
 *
 * 用法：
 *   node scripts/probe-ws.mjs                    # 自动选第一台 online 设备
 *   node scripts/probe-ws.mjs <device_id>
 *
 * 凭证从 ~/.kimi-code/credentials/kimi-code.json 读取，不会被打印。
 */

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';

const RELAY = process.env.KIMI_CODE_REMOTE_CONTROL_RELAY_URL ?? 'https://code-rc.kimi.com';
const WS_BEARER_PREFIX = 'kimi-code.bearer.';
const TIMEOUT_MS = 15_000;

// `ws` 不是本项目依赖，直接借用全局安装的 kimi-code 里那份。
const WS_PATHS = [
  '/opt/homebrew/lib/node_modules/@moonshot-ai/kimi-code/node_modules/ws/index.js',
  'ws',
];
let WebSocket;
for (const p of WS_PATHS) {
  try {
    WebSocket = (await import(p)).WebSocket ?? createRequire(import.meta.url)(p);
    break;
  } catch {}
}
if (!WebSocket) {
  console.error('找不到 ws 模块。装一个：npm i -g ws  或  npm i ws');
  process.exit(1);
}

function loadRefreshToken() {
  const path = join(homedir(), '.kimi-code', 'credentials', 'kimi-code.json');
  try {
    const token = JSON.parse(readFileSync(path, 'utf8')).refresh_token;
    if (typeof token !== 'string' || token.length === 0) throw new Error('no refresh_token');
    return token;
  } catch (error) {
    console.error(`读取 ${path} 失败：${error.message}\n先跑一次 \`kimi login\`。`);
    process.exit(1);
  }
}

async function pickDevice(token) {
  const explicit = process.argv[2];
  if (explicit !== undefined) return explicit;
  const response = await fetch(`${RELAY}/v1/remote/devices`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    console.error(`设备列表拉取失败：HTTP ${response.status}`);
    process.exit(1);
  }
  const { devices = [] } = await response.json();
  const online = devices.find((d) => d.status === 'online');
  if (online === undefined) {
    console.error('没有 online 设备。先在某台机器上跑 `kimi rc`。');
    process.exit(1);
  }
  console.log(`设备：${online.alias} (${online.platform}, ${online.client_version})`);
  return online.device_id;
}

/** 一次握手尝试。resolve 成 { ok, detail }。 */
function attempt(label, wsUrl, { headers = {}, protocols } = {}) {
  return new Promise((resolve) => {
    const socket = new WebSocket(wsUrl, protocols, { headers, handshakeTimeout: TIMEOUT_MS });
    let settled = false;
    const finish = (ok, detail) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        socket.close();
      } catch {}
      console.log(`  ${ok ? '✅' : '❌'} ${label}: ${detail}`);
      resolve({ ok, detail });
    };
    const timer = setTimeout(() => finish(false, '超时，未收到 server_hello'), TIMEOUT_MS);

    socket.on('open', () => {
      // 协商回来的 subprotocol 里含 refresh token，只打印它是否被接受。
      const negotiated =
        socket.protocol === '' || socket.protocol === undefined
          ? 'none'
          : socket.protocol.startsWith(WS_BEARER_PREFIX)
            ? `${WS_BEARER_PREFIX}<redacted>`
            : socket.protocol;
      console.log(`  …  ${label}: socket open (negotiated subprotocol: ${negotiated})`);
    });
    socket.on('message', (data) => {
      let message;
      try {
        message = JSON.parse(String(data));
      } catch {
        return finish(false, `收到非 JSON 帧：${String(data).slice(0, 120)}`);
      }
      if (message.type === 'server_hello') {
        const p = message.payload ?? {};
        console.log(
          `  …  ${label}: server_hello protocol_version=${p.protocol_version} ` +
            `heartbeat_ms=${p.heartbeat_ms} capabilities=${JSON.stringify(p.capabilities)}`,
        );
        // 补一次 client_hello，确认 ack 链路也通。
        socket.send(
          JSON.stringify({
            type: 'client_hello',
            id: randomUUID(),
            payload: { client_id: `probe_${randomUUID().slice(0, 8)}`, subscriptions: [] },
          }),
        );
        return;
      }
      if (message.type === 'ack') {
        return finish(true, `ack code=${message.code} payload=${JSON.stringify(message.payload)}`);
      }
      console.log(`  …  ${label}: ${message.type}`);
    });
    socket.on('unexpected-response', (_req, res) => {
      finish(false, `HTTP ${res.statusCode} ${res.statusMessage ?? ''}`.trim());
    });
    socket.on('error', (error) => finish(false, `error: ${error.message}`));
    socket.on('close', (code, reason) => {
      finish(false, `closed before handshake (${code} ${String(reason)})`);
    });
  });
}

const token = loadRefreshToken();
const deviceId = await pickDevice(token);
const base = new URL(RELAY);
base.protocol = base.protocol === 'https:' ? 'wss:' : 'ws:';
const wsUrl = (() => {
  const url = new URL(base);
  url.pathname = `${base.pathname.replace(/\/+$/, '')}/devices/${encodeURIComponent(deviceId)}/api/v1/ws`;
  url.search = new URLSearchParams({ client_id: `probe_${randomUUID().slice(0, 8)}` }).toString();
  return url.toString();
})();
console.log(`WS: ${wsUrl.replace(/client_id=[^&]*/, 'client_id=…')}\n`);

const results = {
  A: await attempt('A  Authorization 头  ', wsUrl, { headers: { Authorization: `Bearer ${token}` } }),
  B: await attempt('B  subprotocol       ', wsUrl, { protocols: [`${WS_BEARER_PREFIX}${token}`] }),
  C: await attempt('C  无凭证（对照组）  ', wsUrl, {}),
};

console.log('\n结论：');
if (results.A.ok) {
  console.log('  → 用 Authorization 头。URLSessionWebSocketTask 可直接 setValue(_:forHTTPHeaderField:)。');
} else if (results.B.ok) {
  console.log('  → 只能用 subprotocol。URLRequest 里设 Sec-WebSocket-Protocol: kimi-code.bearer.<refresh_token>。');
} else {
  console.log('  → 两种都不通。relay 这一跳可能只认 cookie，需要 ASWebAuthenticationSession 兜底（方案 B）。');
}
if (results.C.ok) console.log('  ⚠️  无凭证也能连上 —— 意料之外，需要复查。');
