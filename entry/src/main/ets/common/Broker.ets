import { http } from '@kit.NetworkKit';

/**
 * Broker —— 星zuku 与 HDC 桥接进程之间的通道。
 *
 * 手机侧三方应用无法提权，因此由电脑上的 starzuku-broker 进程以 `hdc shell`
 * (uid=shell) 执行命令，再通过 `hdc rport` 把结果回送给本应用。
 * 本应用再把能力封装成本地 HTTP 接口（见 ApiServer.ets）供其它应用调用。
 */

export interface ExecResult {
  code: number;
  out: string;
  err: string;
}

export interface HealthInfo {
  ok: boolean;
  sn: string;
  version: string;
  hdc: string;
}

export interface ProcessItem {
  uid: string;
  pid: number;
  name: string;
}

interface ShellReq {
  cmd: string;
  timeout: number;
}

interface PushReq {
  path: string;
  base64: string;
}

interface PullReq {
  path: string;
}

export class Broker {
  static base: string = 'http://127.0.0.1:18791';

  private static async postJson(path: string, body: string, timeout: number): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(Broker.base + path, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: 3000,
        readTimeout: timeout
      });
      if (resp.responseCode !== 200) {
        return '';
      }
      return resp.result as string;
    } catch (e) {
      return '';
    } finally {
      req.destroy();
    }
  }

  static async health(): Promise<HealthInfo | null> {
    const txt = await Broker.postJson('/health', '{}', 5000);
    if (txt.length === 0) {
      return null;
    }
    try {
      return JSON.parse(txt) as HealthInfo;
    } catch (e) {
      return null;
    }
  }

  static async exec(cmd: string, timeout: number = 20000): Promise<ExecResult> {
    const body: ShellReq = { cmd: cmd, timeout: timeout };
    const txt = await Broker.postJson('/exec', JSON.stringify(body), timeout + 4000);
    if (txt.length === 0) {
      const fail: ExecResult = { code: -1, out: '', err: 'broker 未连接（请检查电脑端与 hdc rport）' };
      return fail;
    }
    try {
      return JSON.parse(txt) as ExecResult;
    } catch (e) {
      const fail: ExecResult = { code: -1, out: '', err: '返回数据解析失败' };
      return fail;
    }
  }

  static async push(remotePath: string, base64: string, timeout: number = 90000): Promise<boolean> {
    const body: PushReq = { path: remotePath, base64: base64 };
    const txt = await Broker.postJson('/push', JSON.stringify(body), timeout);
    return txt.indexOf('"ok":true') >= 0;
  }

  static async pull(remotePath: string): Promise<string> {
    const body: PullReq = { path: remotePath };
    const txt = await Broker.postJson('/pull', JSON.stringify(body), 90000);
    if (txt.length === 0) {
      return '';
    }
    return txt;
  }

  /** 拉取设备上的文件，返回 base64 内容（失败返回空串） */
  static async pullBase64(remotePath: string): Promise<string> {
    const raw = await Broker.pull(remotePath);
    if (raw.length === 0) {
      return '';
    }
    try {
      const obj: PullResp = JSON.parse(raw) as PullResp;
      return obj.base64 === undefined ? '' : obj.base64;
    } catch (e) {
      return '';
    }
  }

  // ---------- 具体能力封装 ----------

  static async identify(): Promise<string> {
    const r = await Broker.exec('id; getprop ro.product.model 2>/dev/null || param get const.product.model');
    return r.code === 0 ? r.out.trim() : (r.err.length > 0 ? r.err.trim() : ('exit ' + r.code));
  }

  /** 截屏：返回 jpeg 的 base64（失败返回空串） */
  static async capture(): Promise<string> {
    const r = await Broker.exec(
      'rm -f /data/local/tmp/.sz_shot.jpeg; snapshot_display -f /data/local/tmp/.sz_shot.jpeg >/dev/null 2>&1; ls -l /data/local/tmp/.sz_shot.jpeg',
      30000);
    if (r.out.indexOf('.sz_shot.jpeg') < 0 && r.out.indexOf('No such') >= 0) {
      return '';
    }
    if (r.code !== 0) {
      return '';
    }
    const raw = await Broker.pull('/data/local/tmp/.sz_shot.jpeg');
    if (raw.length === 0) {
      return '';
    }
    try {
      const obj: PullResp = JSON.parse(raw) as PullResp;
      return obj.base64 === undefined ? '' : obj.base64;
    } catch (e) {
      return '';
    }
  }

  static async tap(x: number, y: number): Promise<ExecResult> {
    return Broker.exec('uitest uiInput click ' + Math.round(x) + ' ' + Math.round(y), 15000);
  }

  /** uitest 的第 5 个参数是速度(200~40000)，这里把"时长 ms"换算成速度 */
  static async swipe(x1: number, y1: number, x2: number, y2: number, duration: number): Promise<ExecResult> {
    const dx: number = x2 - x1;
    const dy: number = y2 - y1;
    const dist: number = Math.sqrt(dx * dx + dy * dy);
    const sec: number = duration > 0 ? duration / 1000 : 0.3;
    let v: number = Math.round(dist / sec);
    if (v < 200) {
      v = 200;
    }
    if (v > 40000) {
      v = 40000;
    }
    return Broker.exec('uitest uiInput swipe ' + Math.round(x1) + ' ' + Math.round(y1) + ' '
      + Math.round(x2) + ' ' + Math.round(y2) + ' ' + v, 15000);
  }

  static async keyEvent(name: string): Promise<ExecResult> {
    return Broker.exec('uitest uiInput keyEvent ' + name, 15000);
  }

  static async processText(): Promise<ExecResult> {
    return Broker.exec('ps -ef', 20000);
  }

  static parseProcess(text: string): ProcessItem[] {
    const items: ProcessItem[] = [];
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const t = line.split(/\s+/);
      if (t.length < 3) {
        continue;
      }
      const pid = parseInt(t[1]);
      if (isNaN(pid)) {
        continue;
      }
      const name = t[t.length - 1];
      const item: ProcessItem = { uid: t[0], pid: pid, name: name };
      items.push(item);
    }
    return items;
  }

  static async listDir(path: string): Promise<ExecResult> {
    return Broker.exec('ls -lA "' + path + '"', 20000);
  }

  static async readFile(path: string): Promise<ExecResult> {
    return Broker.exec('cat "' + path + '"', 25000);
  }

  static async writeFile(path: string, content: string): Promise<ExecResult> {
    // 单引号包裹，内部单引号转义为 '\''
    const safe = content.split("'").join("'\\''");
    return Broker.exec("printf '%s' '" + safe + "' > \"" + path + '"', 20000);
  }

  static async removeFile(path: string): Promise<ExecResult> {
    return Broker.exec('rm -f "' + path + '"', 10000);
  }

  static async killProcess(pid: number): Promise<ExecResult> {
    return Broker.exec('kill -9 ' + pid, 15000);
  }

  static async installHap(base64: string, fileName: string): Promise<ExecResult> {
    const remote = '/data/local/tmp/.sz_install.hap';
    const pushed = await Broker.push(remote, base64, 120000);
    if (!pushed) {
      const fail: ExecResult = { code: -1, out: '', err: 'hap 上传失败' };
      return fail;
    }
    return Broker.exec('bm install -p ' + remote + ' -u 100 2>&1 || bm install -p ' + remote, 60000);
  }

  static async uninstall(bundle: string): Promise<ExecResult> {
    return Broker.exec('bm uninstall -n "' + bundle + '"', 30000);
  }

  static async startApp(bundle: string): Promise<ExecResult> {
    return Broker.exec('aa start -a EntryAbility -b "' + bundle + '" 2>&1 || aa start -b "' + bundle + '"', 20000);
  }

  static async appList(): Promise<ExecResult> {
    // -l 一次拿到 bundleName + label，省掉逐包 dump
    return Broker.exec('bm dump -a -l', 40000);
  }

  static async deviceInfo(): Promise<ExecResult> {
    return Broker.exec(
      'echo model=$(param get const.product.model); ' +
      'echo brand=$(param get const.product.brand); ' +
      'echo api=$(param get const.ohos.apiversion); ' +
      'echo ver=$(param get const.product.software.version)', 20000);
  }
}

interface PullResp {
  ok?: boolean;
  base64?: string;
  size?: number;
}
