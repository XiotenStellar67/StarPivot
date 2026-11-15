import { socket } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * LocalHdc —— 免电脑直连：在本机内直接与 hdcd（uid 2000）握手并执行 shell。
 *
 * 协议要点（全部为实测结论）：
 *   帧头 11 字节：'HW' + 00 00 + 01 00 + protoLen(小端 2B) + 00 + payloadLen(大端 2B)
 *   proto 头：08 <channel> 10 <cmd> 18 00 20 09
 *   payload 为 protobuf：1=OHOS HDC, 2=state, 3=ts, 4=target, 5=auth, 6=Ver
 *   握手：state0(hello) -> 设备 state3 -> state3(带 PEM 公钥) -> 设备 state2(带 nonce)
 *        -> state2(带 base64 签名) -> 设备 state4 authstatus SUCCESS
 *   签名：RSA-3072，PSS（MGF1-SHA512，salt=64），摘要 SHA512，签名输入是 nonce 的 ASCII 串
 *   shell：cmd=1001，payload 直接是命令字符串（不要带 "shell " 前缀）
 */

const VER = 'Ver: 3.2.0f73c487f8b34a2ba5';
let pbComplete: boolean = false;
const HELLO_AUTH = 'authtype        1               1supportfeatures 29              Ver: 3.2.0f,TCP,win,heartbeat';
const HOST_TAG = 'STARPIVOT-PAD';
/** 见过 hdcd 监听的端口，先试这些，省掉全段扫描 */
const KNOWN_PORTS: number[] = [46751, 39594];
const PREFS = 'starpivot';
const K_KEY = 'hdcKeyDer';
const K_PUB = 'hdcPubDer';
const K_PORT = 'hdcPort';

interface PbField {
  f: number;
  num: number;
  str: string;
  bin: Uint8Array;
  isBin: boolean;
}

interface RsaKey {
  n: bigint;
  e: bigint;
  d: bigint;
  pem: string;
}

interface TcpReply {
  fields: PbField[];
  raw: string;
  bin: Uint8Array;
}

function lu(m: string): void {
  console.info('[SP-LH] ' + m);
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

// ---------------- protobuf 编解码 ----------------

function varintBytes(v: number): Uint8Array {
  const out: number[] = [];
  let n: number = v;
  while (true) {
    let b: number = n & 0x7F;
    n = n >> 7;
    if (n !== 0) {
      out.push(b | 0x80);
    } else {
      out.push(b);
      break;
    }
  }
  return new Uint8Array(out);
}

/** 手写 UTF-8 编码，避免依赖 native TextEncoder 的 encodeInto */
function encodeUtf8(text: string): Uint8Array {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const c: number = text.charCodeAt(i);
    if (c < 0x80) {
      bytes.push(c);
    } else if (c < 0x800) {
      bytes.push(0xC0 | (c >> 6));
      bytes.push(0x80 | (c & 0x3F));
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
      const c2: number = text.charCodeAt(i + 1);
      const pair: number = 0x10000 + (((c & 0x3FF) << 10) | (c2 & 0x3FF));
      bytes.push(0xF0 | (pair >> 18));
      bytes.push(0x80 | ((pair >> 12) & 0x3F));
      bytes.push(0x80 | ((pair >> 6) & 0x3F));
      bytes.push(0x80 | (pair & 0x3F));
      i++;
    } else {
      bytes.push(0xE0 | (c >> 12));
      bytes.push(0x80 | ((c >> 6) & 0x3F));
      bytes.push(0x80 | (c & 0x3F));
    }
  }
  return new Uint8Array(bytes);
}

function pbStr(field: number, text: string): Uint8Array {
  const data: Uint8Array = encodeUtf8(text);
  const head: Uint8Array = varintBytes((field << 3) | 2);
  const len: Uint8Array = varintBytes(data.length);
  const all: Uint8Array = new Uint8Array(head.length + len.length + data.length);
  all.set(head, 0);
  all.set(len, head.length);
  all.set(data, head.length + len.length);
  return all;
}

function pbInt(field: number, v: number): Uint8Array {
  const head: Uint8Array = varintBytes((field << 3) | 0);
  const val: Uint8Array = varintBytes(v);
  const all: Uint8Array = new Uint8Array(head.length + val.length);
  all.set(head, 0);
  all.set(val, head.length);
  return all;
}

function joinBytes(list: Uint8Array[]): Uint8Array {
  let total: number = 0;
  for (let i = 0; i < list.length; i++) {
    total += list[i].length;
  }
  const out: Uint8Array = new Uint8Array(total);
  let off: number = 0;
  for (let i = 0; i < list.length; i++) {
    out.set(list[i], off);
    off += list[i].length;
  }
  return out;
}

function parsePb(buf: Uint8Array, from: number, to: number): PbField[] {
  pbComplete = false;
  const out: PbField[] = [];
  let i: number = from;
  const dec = new util.TextDecoder();
  while (i < to) {
    let key: number = 0;
    let shift: number = 0;
    while (i < to) {
      const b: number = buf[i];
      i++;
      key = key | ((b & 0x7F) << shift);
      shift += 7;
      if ((b & 0x80) === 0) {
        break;
      }
    }
    const fn: number = key >> 3;
    const wt: number = key & 7;
    if (wt === 0) {
      let v: number = 0;
      let s2: number = 0;
      while (i < to) {
        const b: number = buf[i];
        i++;
        v = v | ((b & 0x7F) << s2);
        s2 += 7;
        if ((b & 0x80) === 0) {
          break;
        }
      }
      const f: PbField = { f: fn, num: v, str: '', bin: new Uint8Array(0), isBin: false };
      out.push(f);
    } else if (wt === 2) {
      let ln: number = 0;
      let s3: number = 0;
      while (i < to) {
        const b: number = buf[i];
        i++;
        ln = ln | ((b & 0x7F) << s3);
        s3 += 7;
        if ((b & 0x80) === 0) {
          break;
        }
      }
      if (i + ln > to) {
        break;
      }
      const slice: Uint8Array = buf.slice(i, i + ln);
      i += ln;
      let text: string = '';
      try {
        text = dec.decodeToString(slice);
      } catch (e) {
        text = '';
      }
      const printable: boolean = text.length > 0 || ln === 0;
      const f2: PbField = { f: fn, num: 0, str: text, bin: slice, isBin: !printable };
      out.push(f2);
    } else {
      break;
    }
  }
  if (i >= to) {
    pbComplete = true;
  }
  return out;
}

function fieldStr(fields: PbField[], name: number): string {
  for (let i = 0; i < fields.length; i++) {
    if (fields[i].f === name && !fields[i].isBin) {
      return fields[i].str;
    }
  }
  return '';
}

function fieldNum(fields: PbField[], name: number): number {
  for (let i = 0; i < fields.length; i++) {
    if (fields[i].f === name && !fields[i].isBin) {
      return fields[i].num;
    }
  }
  return -1;
}

/** 去掉控制字符（保留 \n \r \t），避免把 protobuf 包装字节显示出来 */
function cleanText(s: string): string {
  // 快速通道：没有控制字符（base64、普通日志）就直接返回，避免逐字符重建拖慢大输出
  let dirty: boolean = false;
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c === 9 || c === 10 || c === 13) {
      continue;
    }
    if (c < 32 || c === 127) {
      dirty = true;
      break;
    }
  }
  if (!dirty) {
    return s;
  }
  const codes: number[] = [];
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c === 9 || c === 10 || c === 13) {
      codes.push(c);
    } else if (c >= 32 && c !== 127) {
      codes.push(c);
    }
  }
  const parts: string[] = [];
  for (let i = 0; i < codes.length; i++) {
    parts.push(String.fromCharCode(codes[i]));
  }
  return parts.join('');
}

/** 从 shell 回复帧里取真正的文本：优先取 protobuf 文本字段，取不到再退回原始载荷 */
function frameText(rep: TcpReply): string {
  let t: string = '';
  if (pbComplete) {
    for (let i = 0; i < rep.fields.length; i++) {
      const f: PbField = rep.fields[i];
      if (!f.isBin && f.str.length > 0) {
        t += f.str;
      }
    }
  }
  if (t.length === 0) {
    t = rep.raw;
  }
  return cleanText(t);
}

// ---------------- 帧 ----------------

function buildFrame(cmd: number, payload: Uint8Array, chn: number): Uint8Array {
  const proto: Uint8Array = joinBytes([pbInt(1, chn), pbInt(2, cmd), pbInt(3, 0), pbInt(4, 9)]);
  const head: Uint8Array = new Uint8Array(11);
  head[0] = 0x48;
  head[1] = 0x57;
  head[2] = 0;
  head[3] = 0;
  head[4] = 1;
  head[5] = 0;
  head[6] = proto.length & 0xFF;
  head[7] = (proto.length >> 8) & 0xFF;
  head[8] = 0;
  head[9] = (payload.length >> 8) & 0xFF;
  head[10] = payload.length & 0xFF;
  return joinBytes([head, proto, payload]);
}

function stateMsg(state: number, auth: string, target: string): Uint8Array {
  const parts: Uint8Array[] = [];
  parts.push(pbStr(1, 'OHOS HDC'));
  parts.push(pbInt(2, state));
  parts.push(pbInt(3, state === 0 ? Math.floor(Date.now() / 1000) : 0));
  parts.push(pbStr(4, target));
  parts.push(pbStr(5, auth));
  parts.push(pbStr(6, VER));
  return joinBytes(parts);
}

// ---------------- DER / RSA ----------------

interface DerItem {
  tag: number;
  start: number;
  end: number;
}

function derItems(buf: Uint8Array, from: number, to: number): DerItem[] {
  const out: DerItem[] = [];
  let i: number = from;
  while (i < to) {
    const tag: number = buf[i];
    i++;
    let len: number = buf[i];
    i++;
    if ((len & 0x80) !== 0) {
      const cnt: number = len & 0x7F;
      len = 0;
      for (let k = 0; k < cnt; k++) {
        len = (len << 8) | buf[i];
        i++;
      }
    }
    const start: number = i;
    const end: number = i + len;
    const it: DerItem = { tag: tag, start: start, end: end };
    out.push(it);
    i = end;
    if (end > to) {
      break;
    }
  }
  return out;
}

function derToBig(buf: Uint8Array, from: number, to: number): bigint {
  let v: bigint = 0n;
  for (let i = from; i < to; i++) {
    v = (v << 8n) | BigInt(buf[i]);
  }
  return v;
}

/** 从 PKCS8 私钥 DER 里取出 n / e / d */
function parseRsaPrivate(der: Uint8Array): RsaKey {
  const top: DerItem[] = derItems(der, 0, der.length);
  // top[0] = SEQUENCE(PKCS8)
  const pkcs8: DerItem[] = derItems(der, top[0].start, top[0].end);
  // 第三个元素是 OCTET STRING，里面是 RSAPrivateKey SEQUENCE
  let inner: DerItem[] = [];
  for (let i = 0; i < pkcs8.length; i++) {
    if (pkcs8[i].tag === 0x04) {
      inner = derItems(der, pkcs8[i].start, pkcs8[i].end);
    }
  }
  const items: DerItem[] = derItems(der, inner[0].start, inner[0].end);
  // items: ver, n, e, d, p, q, ...
  const n: bigint = derToBig(der, items[1].start, items[1].end);
  const e: bigint = derToBig(der, items[2].start, items[2].end);
  const d: bigint = derToBig(der, items[3].start, items[3].end);
  const key: RsaKey = { n: n, e: e, d: d, pem: '' };
  return key;
}

function bigToPem(der: Uint8Array): string {
  const b64 = new util.Base64Helper();
  const s: string = b64.encodeToStringSync(der);
  let body: string = '';
  for (let i = 0; i < s.length; i += 64) {
    body += s.substring(i, Math.min(i + 64, s.length)) + '\n';
  }
  return '-----BEGIN PUBLIC KEY-----\n' + body + '-----END PUBLIC KEY-----\n';
}

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let r: bigint = 1n;
  let b: bigint = base % mod;
  let e: bigint = exp;
  while (e > 0n) {
    if ((e & 1n) === 1n) {
      r = (r * b) % mod;
    }
    b = (b * b) % mod;
    e = e >> 1n;
  }
  return r;
}

async function sha512(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA512');
  await md.update({ data: data });
  const out = await md.digest();
  return out.data as Uint8Array;
}

/** MGF1(SHA512) */
async function mgf1(seed: Uint8Array, len: number): Promise<Uint8Array> {
  const out: Uint8Array = new Uint8Array(len);
  let off: number = 0;
  let counter: number = 0;
  while (off < len) {
    const cat: Uint8Array = new Uint8Array(seed.length + 4);
    cat.set(seed, 0);
    cat[seed.length] = (counter >> 24) & 0xFF;
    cat[seed.length + 1] = (counter >> 16) & 0xFF;
    cat[seed.length + 2] = (counter >> 8) & 0xFF;
    cat[seed.length + 3] = counter & 0xFF;
    const h: Uint8Array = await sha512(cat);
    const take: number = Math.min(h.length, len - off);
    out.set(h.slice(0, take), off);
    off += take;
    counter++;
  }
  return out;
}

/** RSASSA-PSS 签名：SHA512 + MGF1-SHA512 + salt 64 */
async function pssSign(key: RsaKey, msg: string): Promise<Uint8Array> {
  const emLen: number = 384;      // 3072 位 -> 384 字节
  const hLen: number = 64;
  const sLen: number = 64;
  const enc = new util.TextEncoder();
  const mHash: Uint8Array = await sha512(enc.encodeInto(msg));
  // salt：用时间戳派生，PSS 允许确定性盐，避免额外依赖随机源
  const seedStr: string = String(Date.now()) + ':' + String(Math.floor(Math.random() * 1000000)) + msg;
  const saltFull: Uint8Array = await sha512(enc.encodeInto(seedStr));
  const salt: Uint8Array = saltFull.slice(0, sLen);
  const mPrime: Uint8Array = joinBytes([new Uint8Array(8), mHash, salt]);
  const h: Uint8Array = await sha512(mPrime);
  const dbLen: number = emLen - hLen - 1;
  const db: Uint8Array = new Uint8Array(dbLen);
  const psLen: number = dbLen - sLen - 1;
  for (let i = 0; i < psLen; i++) {
    db[i] = 0;
  }
  db[psLen] = 0x01;
  db.set(salt, psLen + 1);
  const mask: Uint8Array = await mgf1(h, dbLen);
  const masked: Uint8Array = new Uint8Array(dbLen);
  for (let i = 0; i < dbLen; i++) {
    masked[i] = db[i] ^ mask[i];
  }
  // 3072 位模数，emBits = 3071 -> 首字节最高位清零
  masked[0] = masked[0] & 0x7F;
  const em: Uint8Array = joinBytes([masked, h, new Uint8Array([0xBC])]);
  const m: bigint = derToBig(em, 0, em.length);
  const s: bigint = modPow(m, key.d, key.n);
  const sig: Uint8Array = new Uint8Array(emLen);
  let v: bigint = s;
  for (let i = emLen - 1; i >= 0; i--) {
    sig[i] = Number(v & 0xFFn);
    v = v >> 8n;
  }
  return sig;
}

// ---------------- 会话 ----------------

export class LocalHdc {
  private static key: RsaKey | null = null;
  static port: number = 0;
  private static tcp: socket.TCPSocket | null = null;
  private static rx: Uint8Array = new Uint8Array(0);
  private static rxLen: number = 0;
  private static alive: boolean = false;
  private static chn: number = 0;
  private static lock: Promise<void> = Promise.resolve();
  static lastError: string = '';
  static phase: string = '';
  /** 已确认不是 hdcd 的端口，本轮连接内跳过 */
  private static skipPorts: number[] = [];
  /** 单飞：同一时刻只允许一次握手，避免两条请求同时建连把 rx 冲掉 */
  private static connecting: Promise<boolean> | null = null;

  private static async getPrefs(ctx: common.UIAbilityContext): Promise<preferences.Preferences> {
    return await preferences.getPreferences(ctx, PREFS);
  }

  /** 载入（或首次生成）本机密钥，RSA-3072 */
  static async ensureKey(ctx: common.UIAbilityContext): Promise<boolean> {
    if (LocalHdc.key !== null) {
      return true;
    }
    try {
      const store: preferences.Preferences = await LocalHdc.getPrefs(ctx);
      const saved: string = store.getSync(K_KEY, '') as string;
      const savedPub: string = store.getSync(K_PUB, '') as string;
      if (saved.length > 100 && savedPub.length > 100) {
        const b64 = new util.Base64Helper();
        const der: Uint8Array = b64.decodeSync(saved);
        const key: RsaKey = parseRsaPrivate(der);
        key.pem = bigToPem(b64.decodeSync(savedPub));
        LocalHdc.key = key;
        LocalHdc.port = store.getSync(K_PORT, 0) as number;
        return true;
      }
      const gen = cryptoFramework.createAsyKeyGenerator('RSA3072');
      const kp: cryptoFramework.KeyPair = await gen.generateKeyPair();
      const prv = kp.priKey.getEncodedDer('PKCS8');
      const pub = kp.pubKey.getEncodedDer('X509');
      const derBytes: Uint8Array = prv.data as Uint8Array;
      const key: RsaKey = parseRsaPrivate(derBytes);
      key.pem = bigToPem(pub.data as Uint8Array);
      LocalHdc.key = key;
      const b64 = new util.Base64Helper();
      await store.put(K_KEY, b64.encodeToStringSync(derBytes));
      await store.put(K_PUB, b64.encodeToStringSync(pub.data as Uint8Array));
      await store.flush();
      return true;
    } catch (e) {
      const err = e as BusinessError;
      LocalHdc.lastError = '密钥初始化失败：' + err.message;
      return false;
    }
  }

  static async publicKeyPem(ctx: common.UIAbilityContext): Promise<string> {
    const ok: boolean = await LocalHdc.ensureKey(ctx);
    if (!ok || LocalHdc.key === null) {
      return '';
    }
    return LocalHdc.key.pem;
  }

  /** 从 /proc/net/tcp(6) 里找 uid 2000 的监听端口 */
  private static guessFromProc(): number[] {
    const ports: number[] = [];
    const files: string[] = ['/proc/net/tcp', '/proc/net/tcp6'];
    for (let f = 0; f < files.length; f++) {
      try {
        const txt: string = fs.readTextSync(files[f]);
        const lines: string[] = txt.split('\n');
        for (let i = 1; i < lines.length; i++) {
          const parts: string[] = lines[i].trim().split(/\s+/);
          if (parts.length < 8) {
            continue;
          }
          const local: string = parts[1];
          const state: string = parts[3];
          const uid: string = parts[7];
          if (state !== '0A' || uid !== '2000') {
            continue;
          }
          const hexPort: string = local.substring(local.lastIndexOf(':') + 1);
          const p: number = parseInt(hexPort, 16);
          if (p > 0 && p < 65536 && ports.indexOf(p) < 0) {
            ports.push(p);
          }
        }
      } catch (e) {
        lu('读取 ' + files[f] + ' 失败: ' + (e as BusinessError).message);
      }
    }
    lu('proc 候选端口: ' + ports.join(','));
    return ports;
  }

  /** 建一个到 127.0.0.1:port 的 TCP socket；失败返回 null（任何异常都不外抛） */
  private static async makeSocket(port: number, timeout: number): Promise<socket.TCPSocket | null> {
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
    } catch (e) {
      lu('construct socket 失败: ' + (e as BusinessError).message);
      return null;
    }
    const sock: socket.TCPSocket = tcp;
    try {
      await sock.connect({
        address: { address: '127.0.0.1', port: port, family: 1 },
        timeout: timeout
      });
    } catch (e) {
      try {
        sock.close();
      } catch (e2) {
      }
      return null;
    }
    // 注意：connect 之后才挂回调，否则回调会被 connect 覆盖，收到的帧全部丢失
    try {
      sock.on('message', (info: socket.SocketMessageInfo) => {
        try {
          LocalHdc.appendRx(new Uint8Array(info.message));
        } catch (e) {
        }
      });
      sock.on('close', () => {
        LocalHdc.alive = false;
      });
      sock.on('error', (e: BusinessError) => {
        LocalHdc.alive = false;
        lu('socket error: ' + e.message);
      });
    } catch (e) {
      lu('挂回调失败: ' + (e as BusinessError).message);
    }
    return sock;
  }

  /** 把一条候选连接装进会话，并发 hello 验证；只有真 hdcd 才算命中 */
  private static async adoptAndProbe(sock: socket.TCPSocket, port: number): Promise<boolean> {
    LocalHdc.port = port;
    LocalHdc.tcp = sock;
    LocalHdc.resetRx();
    LocalHdc.alive = true;
    LocalHdc.chn = 0;
    const target: string = '127.0.0.1:' + String(port);
    lu('已连上 ' + target + '，探测 hello');
    let ok: boolean = false;
    try {
      ok = await LocalHdc.probeHello(target);
    } catch (e) {
      const err = e as BusinessError;
      const m: string = err !== null && err.message !== undefined ? err.message : String(e);
      lu('hello 阶段异常: ' + m);
      ok = false;
    }
    if (!ok) {
      lu('端口 ' + String(port) + ' 不是 hdcd，跳过');
      LocalHdc.skipPorts.push(port);
      LocalHdc.close();
    }
    return ok;
  }

  /** 找 hdcd 端口：已知端口 -> 缓存端口 -> /proc -> 扫临时端口段；每条命中都先 hello 验证 */
  static async discover(ctx: common.UIAbilityContext, fast: boolean): Promise<socket.TCPSocket | null> {
    const cand: number[] = [];
    for (let i = 0; i < KNOWN_PORTS.length; i++) {
      cand.push(KNOWN_PORTS[i]);
    }
    if (LocalHdc.port > 0 && cand.indexOf(LocalHdc.port) < 0) {
      cand.push(LocalHdc.port);
    }
    const procPorts: number[] = LocalHdc.guessFromProc();
    for (let i = 0; i < procPorts.length; i++) {
      if (cand.indexOf(procPorts[i]) < 0) {
        cand.push(procPorts[i]);
      }
    }
    LocalHdc.phase = '尝试候选端口 ' + String(cand.length) + ' 个';
    for (let i = 0; i < cand.length; i++) {
      if (LocalHdc.skipPorts.indexOf(cand[i]) >= 0) {
        continue;
      }
      const sock: socket.TCPSocket | null = await LocalHdc.makeSocket(cand[i], 1500);
      if (sock !== null) {
        if (await LocalHdc.adoptAndProbe(sock, cand[i])) {
          await LocalHdc.savePort(ctx, cand[i]);
          return LocalHdc.tcp;
        }
      }
    }
    if (fast) {
      LocalHdc.phase = '候选端口均不可用';
      return null;
    }
    // 扫 Linux 临时端口段（hdcd 由 bind(0) 分配，一般落在这里）
    const LO: number = 32768;
    const HI: number = 61000;
    const STEP: number = 64;
    for (let base = LO; base < HI; base += STEP) {
      LocalHdc.phase = '扫描端口 ' + String(base) + '-' + String(Math.min(base + STEP, HI));
      const tasks: Promise<socket.TCPSocket | null>[] = [];
      for (let k = 0; k < STEP; k++) {
        const p: number = base + k;
        if (p >= HI) {
          break;
        }
        tasks.push(LocalHdc.makeSocket(p, 260));
      }
      const hits: socket.TCPSocket[] = [];
      const hitPorts: number[] = [];
      try {
        const all: (socket.TCPSocket | null)[] = await Promise.all(tasks);
        for (let i = 0; i < all.length; i++) {
          const candP: number = base + i;
          if (all[i] === null) {
            continue;
          }
          if (LocalHdc.skipPorts.indexOf(candP) >= 0) {
            try {
              (all[i] as socket.TCPSocket).close();
            } catch (e) {
            }
            continue;
          }
          hits.push(all[i] as socket.TCPSocket);
          hitPorts.push(candP);
        }
      } catch (e) {
      }
      // 本段内逐个验证：假命中的端口会在这里被剔掉，继续下一段
      for (let j = 0; j < hits.length; j++) {
        const ok: boolean = await LocalHdc.adoptAndProbe(hits[j], hitPorts[j]);
        if (ok) {
          await LocalHdc.savePort(ctx, hitPorts[j]);
          return LocalHdc.tcp;
        }
      }
    }
    LocalHdc.phase = '扫描完毕，未找到监听端口';
    return null;
  }

  private static async savePort(ctx: common.UIAbilityContext, p: number): Promise<void> {
    try {
      LocalHdc.phase = '端口 ' + String(p);
      const store: preferences.Preferences = await LocalHdc.getPrefs(ctx);
      await store.put(K_PORT, p);
      await store.flush();
    } catch (e) {
    }
  }

  private static async send(bytes: Uint8Array): Promise<void> {
    if (LocalHdc.tcp === null) {
      throw new Error('socket 未连接');
    }
    const buf: ArrayBuffer = new ArrayBuffer(bytes.length);
    const view: Uint8Array = new Uint8Array(buf);
    view.set(bytes);
    await LocalHdc.tcp.send({ data: buf });
    lu('已发送 ' + String(bytes.length) + ' 字节');
  }

  /** 追加入缓冲：容量翻倍扩容，避免每块都整段拷贝 */
  private static appendRx(chunk: Uint8Array): void {
    if (LocalHdc.rxLen + chunk.length > LocalHdc.rx.length) {
      let cap: number = LocalHdc.rx.length > 0 ? LocalHdc.rx.length : 4096;
      while (cap < LocalHdc.rxLen + chunk.length) {
        cap = cap * 2;
      }
      const grown: Uint8Array = new Uint8Array(cap);
      if (LocalHdc.rxLen > 0) {
        grown.set(LocalHdc.rx.subarray(0, LocalHdc.rxLen), 0);
      }
      LocalHdc.rx = grown;
    }
    LocalHdc.rx.set(chunk, LocalHdc.rxLen);
    LocalHdc.rxLen += chunk.length;
  }

  private static resetRx(): void {
    LocalHdc.rx = new Uint8Array(0);
    LocalHdc.rxLen = 0;
  }

  /** 读一帧，超时返回 null */
  private static async readFrame(timeoutMs: number): Promise<TcpReply | null> {
    const end: number = Date.now() + timeoutMs;
    while (true) {
      if (LocalHdc.rxLen >= 11) {
        const protoLen: number = LocalHdc.rx[6] + (LocalHdc.rx[7] << 8);
        const payLen: number = (LocalHdc.rx[9] << 8) + LocalHdc.rx[10];
        const total: number = 11 + protoLen + payLen;
        if (LocalHdc.rxLen >= total) {
          const frame: Uint8Array = LocalHdc.rx.subarray(0, total).slice(0);
          // 消费掉这一帧：剩余内容前移
          const rest: number = LocalHdc.rxLen - total;
          if (rest > 0) {
            LocalHdc.rx.copyWithin(0, total, LocalHdc.rxLen);
          }
          LocalHdc.rxLen = rest;
          const fields: PbField[] = parsePb(frame, 11 + protoLen, total);
          const dec = new util.TextDecoder();
          let raw: string = '';
          try {
            raw = dec.decodeToString(frame.slice(11 + protoLen, total));
          } catch (e) {
            raw = '';
          }
          const rep: TcpReply = { fields: fields, raw: raw, bin: frame.slice(11 + protoLen, total) };
          return rep;
        }
      }
      if (!LocalHdc.alive) {
        return null;
      }
      if (Date.now() > end) {
        return null;
      }
      await sleep(6);
    }
  }

  /** 建立连接 + 握手鉴权（socket 由 discover 命中时直接复用） */
  /** 串行锁：取锁后必须 release */
  private static async acquireLock(): Promise<() => void> {
    const prev: Promise<void> = LocalHdc.lock;
    let release: () => void = () => {
    };
    LocalHdc.lock = new Promise<void>((resolve: () => void) => {
      release = () => {
        resolve();
      };
    });
    await prev;
    return release;
  }

  /** 已存活就直接复用；否则全局单飞建连，绝不再并发握手 */
  static async connect(ctx: common.UIAbilityContext, fast: boolean): Promise<boolean> {
    if (LocalHdc.isAlive()) {
      return true;
    }
    if (LocalHdc.connecting !== null) {
      return await LocalHdc.connecting;
    }
    const p: Promise<boolean> = LocalHdc.connectOnce(ctx, fast);
    LocalHdc.connecting = p;
    let ok: boolean = false;
    try {
      ok = await p;
    } finally {
      LocalHdc.connecting = null;
    }
    return ok;
  }

  /** 建连一定要在全局锁里做：任何在途 exec 都不该被换 socket */
  static async connectLocked(ctx: common.UIAbilityContext, fast: boolean): Promise<boolean> {
    const release: () => void = await LocalHdc.acquireLock();
    try {
      return await LocalHdc.connect(ctx, fast);
    } finally {
      release();
    }
  }

  private static async connectOnce(ctx: common.UIAbilityContext, fast: boolean): Promise<boolean> {
    LocalHdc.lastError = '';
    LocalHdc.phase = '准备密钥';
    try {
      return await LocalHdc.connectInner(ctx, fast);
    } catch (e) {
      const err = e as BusinessError;
      const msg: string = err !== null && err.message !== undefined && err.message.length > 0
        ? err.message : String(e);
      LocalHdc.lastError = '连接异常：' + msg;
      lu('connect 抛出异常: ' + msg);
      if (err !== null && err.stack !== undefined) {
        lu('stack: ' + err.stack.split('\n').slice(0, 4).join(' | '));
      }
      LocalHdc.close();
      return false;
    }
  }

  private static async connectInner(ctx: common.UIAbilityContext, fast: boolean): Promise<boolean> {
    const keyOk: boolean = await LocalHdc.ensureKey(ctx);
    if (!keyOk || LocalHdc.key === null) {
      return false;
    }
    lu('密钥就绪, pem 长度 ' + String(LocalHdc.key.pem.length));
    LocalHdc.phase = '查找端口';
    // discover 内部已对每条命中做完 hello 验证，返回的连接一定是真 hdcd
    const sock: socket.TCPSocket | null = await LocalHdc.discover(ctx, fast);
    if (sock === null) {
      LocalHdc.lastError = LocalHdc.phase;
      lu('未找到端口: ' + LocalHdc.phase);
      LocalHdc.skipPorts = [];
      return false;
    }
    if (LocalHdc.tcp === null) {
      LocalHdc.tcp = sock;
      LocalHdc.alive = true;
    }
    lu('端口 ' + String(LocalHdc.port) + ' 已通过 hello 验证，开始鉴权');
    try {
      return await LocalHdc.authFlow();
    } finally {
      if (!LocalHdc.alive) {
        LocalHdc.skipPorts.push(LocalHdc.port);
      }
    }
  }

  /** hello 探测：发 hello 帧并等第一帧；能收到 hdcd 的握手横幅才算这个端口上是 hdcd */
  private static async probeHello(target: string): Promise<boolean> {
    LocalHdc.phase = '发送 hello';
    const helloFrame: Uint8Array = buildFrame(1, stateMsg(0, HELLO_AUTH, target), 0);
    await LocalHdc.send(helloFrame);
    const hello: TcpReply | null = await LocalHdc.readFrame(2000);
    if (hello === null) {
      return false;
    }
    if (hello.fields.length === 0) {
      return false;
    }
    const st: number = fieldNum(hello.fields, 2);
    const banner: string = hello.raw;
    lu('hello 回复: state=' + String(st) + ' len=' + String(banner.length)
      + ' head=' + banner.substring(0, 60).split('\n').join(' '));
    // hdcd 的 hello 回复里必带版本横幅（Ver: x.x.x）或 authtype/supportfeatures；
    // 注意 state 不是 3——真实设备这里返回 0，不能按 state 判断。
    if (banner.indexOf('Ver:') >= 0 || banner.indexOf('authtype') >= 0
      || banner.indexOf('supportfeatures') >= 0) {
      return true;
    }
    // 兜底：老固件可能只回一个 state 帧、横幅字段被裁掉
    return st >= 1 && st <= 4;
  }

  private static async authFlow(): Promise<boolean> {
    // 鉴权请求
    LocalHdc.phase = '等待设备授权';
    let step: string = 'read-pem';
    try {
      const pem: string = LocalHdc.key === null ? '' : LocalHdc.key.pem;
      lu('pem 再次读取长度 ' + String(pem.length));
      step = 'build-text';
      const authText: string = HOST_TAG + '\x0c' + pem;
      lu('auth 文本长度 ' + String(authText.length));
      step = 'build-payload';
      const authPayload: Uint8Array = stateMsg(3, authText, '');
      lu('auth payload 长度 ' + String(authPayload.length));
      step = 'build-frame';
      const authFrame: Uint8Array = buildFrame(1, authPayload, 0);
      lu('auth 帧长度 ' + String(authFrame.length));
      step = 'send';
      await LocalHdc.send(authFrame);
      lu('已发鉴权请求');
    } catch (e) {
      const err = e as BusinessError;
      lu('鉴权请求阶段 [' + step + '] 异常: ' + (err !== null && err.message !== undefined ? err.message : String(e)));
      throw new Error(step);
    }
    let nonce: string = '';
    let sawUnauth: boolean = false;
    const endA: number = Date.now() + 40000;
    while (Date.now() < endA) {
      const rep: TcpReply | null = await LocalHdc.readFrame(6000);
      if (rep === null) {
        if (LocalHdc.alive) {
          continue;      // 只是等弹窗，连接还在
        }
        lu('等待 nonce 时连接断开');
        break;
      }
      const st: number = fieldNum(rep.fields, 2);
      const txt: string = fieldStr(rep.fields, 5);
      lu('auth 回复 state=' + String(st) + ' text=' + txt.substring(0, 80).split('\n').join(' '));
      if (st === 2 && txt.length > 0) {
        nonce = txt;
        break;
      }
      if (txt.indexOf('unauthor') >= 0 || txt.indexOf('E000002') >= 0) {
        sawUnauth = true;
        LocalHdc.lastError = '等待设备授权：请在平板的授权弹窗上点「始终允许」';
        continue;
      }
      if (st === 4) {
        LocalHdc.lastError = txt.length > 0 ? txt : '设备未授权';
        return false;
      }
    }
    if (nonce.length === 0) {
      LocalHdc.lastError = sawUnauth
        ? '等待设备授权超时：请在平板的授权弹窗上点「始终允许」后重试'
        : '未拿到 nonce：设备未返回鉴权挑战';
      return false;
    }
    lu('拿到 nonce: ' + nonce);
    LocalHdc.phase = '签名中';
    const sigKey: RsaKey | null = LocalHdc.key;
    if (sigKey === null) {
      LocalHdc.lastError = '密钥丢失';
      return false;
    }
    const sig: Uint8Array = await pssSign(sigKey, nonce);
    lu('签名完成长度 ' + String(sig.length));
    const b64 = new util.Base64Helper();
    await LocalHdc.send(buildFrame(1, stateMsg(2, b64.encodeToStringSync(sig), ''), 0));
    LocalHdc.phase = '等待鉴权结果';
    const endB: number = Date.now() + 12000;
    while (Date.now() < endB) {
      const rep: TcpReply | null = await LocalHdc.readFrame(6000);
      if (rep === null) {
        break;
      }
      const txt: string = fieldStr(rep.fields, 5);
      lu('after-sign state=' + String(fieldNum(rep.fields, 2)) + ' text=' + txt.substring(0, 80));
      if (txt.indexOf('SUCCESS') >= 0) {
        LocalHdc.phase = '已连接';
        lu('鉴权成功');
        // 握手阶段的残留帧（hello 横幅、devname 之类）不能漏进第一条命令的输出
        LocalHdc.resetRx();
        LocalHdc.chn = 0;
        return true;
      }
      if (txt.indexOf('Auth failed') >= 0 || txt.indexOf('unauth') >= 0) {
        LocalHdc.lastError = '签名被拒：' + txt;
        return false;
      }
    }
    LocalHdc.lastError = '鉴权无响应';
    return false;
  }

  static isAlive(): boolean {
    return LocalHdc.alive && LocalHdc.tcp !== null;
  }

  static close(): void {
    if (LocalHdc.tcp !== null) {
      try {
        LocalHdc.tcp.close();
      } catch (e) {
      }
    }
    LocalHdc.tcp = null;
    LocalHdc.alive = false;
    LocalHdc.resetRx();
  }

  /** 在已鉴权连接上执行一条 shell 命令；endMark 非空时收到该标记立即结束，不必空等 */
  static async rawExec(cmd: string, timeout: number, endMark: string = ''): Promise<string> {
    LocalHdc.chn++;
    const chn: number = LocalHdc.chn;
    await LocalHdc.send(buildFrame(1001, encodeUtf8(cmd), chn));
    const parts: string[] = [];
    const end: number = Date.now() + timeout;
    let idleMs: number = 0;
    let frames: number = 0;
    let rawBytes: number = 0;
    let tail: string = '';
    let hitMark: boolean = false;
    // 小输出用短空闲窗口，避免每条命令都白等 2.5 秒；大输出放宽，防止截断
    while (Date.now() < end) {
      const rep: TcpReply | null = await LocalHdc.readFrame(endMark.length > 0 ? 150 : 250);
      const idleLimit: number = parts.length > 64 ? 2500 : 700;
      if (rep === null) {
        idleMs += endMark.length > 0 ? 150 : 250;
        if (parts.length > 0 && idleMs >= idleLimit) {
          break;
        }
        if (idleMs >= timeout) {
          break;
        }
        continue;
      }
      idleMs = 0;
      if (rep.raw.length === 0) {
        continue;
      }
      if (rep.raw === '\x01' || rep.raw === '$') {
        continue;
      }
      frames++;
      rawBytes += rep.raw.length;
      // 字符串拼接改数组，避免几百 KB 输出时 O(n²) 拷贝
      parts.push(frameText(rep));
      if (endMark.length > 0) {
        const probe: string = tail + parts[parts.length - 1];
        if (probe.indexOf(endMark) >= 0) {
          hitMark = true;
          break;
        }
        tail = probe.length > 64 ? probe.substring(probe.length - 64) : probe;
      }
    }
    let out: string = parts.join('');
    const mu: number = endMark.length > 0 ? out.indexOf(endMark) : -1;
    if (mu >= 0) {
      out = out.substring(0, mu);
    }
    const tail30: string = out.length > 30 ? out.substring(out.length - 30) : out;
    lu('exec 结束，输出 ' + String(out.length) + '/' + String(rawBytes) + ' 字节，帧 ' +
      String(frames) + (hitMark ? '，命中结束标记' : '') + ' 尾部[' + tail30 + ']');
    return out;
  }

  /** 串行执行：内部保证同一时刻只有一个会话在用，断链自动重连一次 */
  static async exec(ctx: common.UIAbilityContext, cmd: string, timeout: number,
                    endMark: string = ''): Promise<string> {
    const release: () => void = await LocalHdc.acquireLock();
    try {
      if (!LocalHdc.isAlive()) {
        const ok: boolean = await LocalHdc.connect(ctx, true);
        if (!ok) {
          throw new Error(LocalHdc.lastError);
        }
      }
      try {
        return await LocalHdc.rawExec(cmd, timeout, endMark);
      } catch (e) {
        // 设备侧把会话断了（hdcd 重启/休眠回收）：关掉重连一次再发
        const m: string = (e as Error).message;
        lu('exec 异常，尝试重连: ' + m);
        LocalHdc.close();
        const ok2: boolean = await LocalHdc.connect(ctx, true);
        if (!ok2) {
          throw new Error(LocalHdc.lastError);
        }
        return await LocalHdc.rawExec(cmd, timeout, endMark);
      }
    } finally {
      release();
    }
  }
}
