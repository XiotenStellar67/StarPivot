#!/usr/bin/env node
/**
 * 星zuku · 电脑端 HDC 桥接（broker）
 *
 * 作用：把 `hdc shell`（设备上 uid=shell）的能力，通过 hdc rport 反向端口转发
 * 暴露给手机上的「星zuku」App，进而由 App 封装成 HTTP 接口给其它应用调用。
 *
 * 启动：双击 start-starzuku.bat，或 `node broker.js`
 */
'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const HOST_PORT = Number(process.env.STARZUKU_PORT || 18791);
const HDC = process.env.HDC ||
  'D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
let SN = process.env.STARZUKU_SN || '';
const VERSION = '0.1';

function log(...args) {
  const t = new Date().toTimeString().slice(0, 8);
  console.log('[' + t + ']', ...args);
}

function hdcRun(args, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    const child = spawn(HDC, args, { windowsHide: true });
    let out = '';
    let err = '';
    const timer = setTimeout(() => {
      if (!done) {
        done = true;
        try { child.kill(); } catch (e) {}
        resolve({ code: 124, out: out, err: err + '\n[hdc timeout]' });
      }
    }, timeoutMs || 20000);
    child.stdout.on('data', (d) => { out += d.toString('utf8'); });
    child.stderr.on('data', (d) => { err += d.toString('utf8'); });
    child.on('error', (e) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code: 127, out: '', err: String(e && e.message) });
    });
    child.on('close', (code) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ code: code === null ? 1 : code, out: out, err: err });
    });
  });
}

async function detectDevice() {
  if (SN) return SN;
  const r = await hdcRun(['list', 'targets'], 8000);
  const lines = (r.out || '').split(/\r?\n/).map((s) => s.trim())
    .filter((s) => s.length > 0 && !s.startsWith('[') && s.toLowerCase() !== 'empty');
  if (lines.length === 0) return '';
  SN = lines[0];
  return SN;
}

/** 执行远端 shell，返回 remote exit code + 输出 */
async function remoteExec(cmd, timeoutMs) {
  const sn = await detectDevice();
  if (!sn) return { code: 2, out: '', err: '没有找到已连接的鸿蒙设备（hdc list targets 为空）' };
  const wrapped = `${cmd}\n__STARZUKU_RC=$?; echo "__STARZUKU_RC=$__STARZUKU_RC"`;
  const r = await hdcRun(['-t', sn, 'shell', wrapped], timeoutMs || 20000);
  let code = r.code;
  let out = r.out;
  const idx = out.lastIndexOf('__STARZUKU_RC=');
  if (idx >= 0) {
    const tail = out.slice(idx + 14).trim();
    const nl = tail.indexOf('\n');
    const numStr = (nl >= 0 ? tail.slice(0, nl) : tail).replace(/[^\d-]/g, '');
    if (numStr.length > 0) code = Number(numStr);
    out = out.slice(0, idx).replace(/\s+$/, '');
  }
  return { code: code, out: out, err: r.err };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => { data += c.toString('utf8'); });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

function send(res, obj) {
  const body = typeof obj === 'string' ? obj : JSON.stringify(obj);
  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body)
  });
  res.end(body);
}

async function main() {
  if (!fs.existsSync(HDC)) {
    log('找不到 hdc.exe：' + HDC);
    log('请设置环境变量 HDC 指向 hdc.exe 后重试。');
  }
  const sn = await detectDevice();
  if (!sn) {
    log('警告：当前没有连接的设备，插上设备后 App 侧点“重新检测”。');
  } else {
    log('设备：' + sn);
  }

  const server = http.createServer(async (req, res) => {
    const url = (req.url || '/').split('?')[0];
    if (url === '/health' || url === '/') {
      const s = await detectDevice();
      return send(res, { ok: true, sn: s, version: VERSION, hdc: HDC });
    }
    const body = await readBody(req);
    let j = {};
    try { j = body ? JSON.parse(body) : {}; } catch (e) {
      return send(res, { ok: false, code: 400, out: '', err: 'bad json' });
    }
    if (url === '/exec') {
      const r = await remoteExec(String(j.cmd || ''), Number(j.timeout || 20000));
      return send(res, { ok: r.code === 0, code: r.code, out: r.out, err: r.err });
    }
    if (url === '/push') {
      const tmp = path.join(os.tmpdir(), 'starzuku_push_' + Date.now() + '.bin');
      try {
        fs.writeFileSync(tmp, Buffer.from(String(j.base64 || ''), 'base64'));
        const s = await detectDevice();
        const r = await hdcRun(['-t', s, 'file', 'send', tmp, String(j.path || '/data/local/tmp/.sz_push')], 120000);
        if (r.code === 0) await remoteExec('chmod 644 ' + JSON.stringify(String(j.path)), 10000);
        return send(res, { ok: r.code === 0, code: r.code, out: r.out, err: r.err, size: fs.statSync(tmp).size });
      } finally {
        try { fs.unlinkSync(tmp); } catch (e) {}
      }
    }
    if (url === '/pull') {
      const tmp = path.join(os.tmpdir(), 'starzuku_pull_' + Date.now() + '.bin');
      try {
        const s = await detectDevice();
        const r = await hdcRun(['-t', s, 'file', 'recv', String(j.path || ''), tmp], 120000);
        if (r.code !== 0) return send(res, { ok: false, code: r.code, out: r.out, err: r.err, base64: '' });
        const buf = fs.readFileSync(tmp);
        return send(res, { ok: true, code: 0, size: buf.length, base64: buf.toString('base64') });
      } finally {
        try { fs.unlinkSync(tmp); } catch (e) {}
      }
    }
    send(res, { ok: false, code: 404, out: '', err: 'unknown endpoint' });
  });

  server.on('error', (e) => {
    if (e && e.code === 'EADDRINUSE') {
      log('端口 ' + HOST_PORT + ' 已被占用：已经有一个 broker 在运行（127.0.0.1:' + HOST_PORT + '）。');
      log('无需重复启动。如果要换这一份启动，先结束旧的 node.exe：');
      log('  任务管理器 -> 结束 node.exe，或执行： taskkill /f /im node.exe');
      process.exit(0);
    }
    throw e;
  });

  server.listen(HOST_PORT, '127.0.0.1', async () => {    log('broker 监听 127.0.0.1:' + HOST_PORT);
    const s = await detectDevice();
    if (s) {
      const r1 = await hdcRun(['-t', s, 'rport', `tcp:${HOST_PORT}`, `tcp:${HOST_PORT}`], 10000);
      if (r1.code === 0) {
        log('已建立反向端口转发：设备 127.0.0.1:' + HOST_PORT + ' → 电脑 ' + HOST_PORT);
      } else {
        log('反向端口转发失败：' + (r1.out + r1.err).trim());
        log('可手动执行：hdc -t ' + s + ' rport tcp:' + HOST_PORT + ' tcp:' + HOST_PORT);
      }
    }
    log('保持此窗口运行；关闭窗口即断开桥接。');
  });
}

main();
