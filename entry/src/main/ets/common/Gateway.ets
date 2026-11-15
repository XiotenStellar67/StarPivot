import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { Broker, ExecResult, HealthInfo, ProcessItem } from './Broker';
import { LocalHdc } from './LocalHdc';

/**
 * Gateway —— 两条通道（电脑 broker / 本机直连 hdcd）的统一门面。
 *
 * mode:
 *   'auto'   —— 电脑 broker 在线就用电脑；否则走本机直连（默认）
 *   'pc'     —— 只用电脑 broker
 *   'local'  —— 只用本机直连
 */

const PREFS = 'starpivot';
const K_MODE = 'connMode';

export class Gateway {
  static mode: string = 'auto';
  static localOk: boolean = false;
  static pcOk: boolean = false;
  static active: string = 'none';   // 'pc' | 'local' | 'none'
  static lastError: string = '';

  private static ctx: common.UIAbilityContext | null = null;
  private static checkedAt: number = 0;
  /** 设备信息缓存：ping 不必每次都跑 param get */
  private static infoCache: HealthInfo | null = null;

  static init(ctx: common.UIAbilityContext): void {
    Gateway.ctx = ctx;
    try {
      preferences.getPreferences(ctx, PREFS).then((store: preferences.Preferences) => {
        Gateway.mode = store.getSync(K_MODE, 'auto') as string;
      }).catch(() => {
      });
    } catch (e) {
    }
  }

  static async setMode(ctx: common.UIAbilityContext, mode: string): Promise<void> {
    Gateway.mode = mode;
    Gateway.checkedAt = 0;
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, PREFS);
      await store.put(K_MODE, mode);
      await store.flush();
    } catch (e) {
    }
    if (mode === 'local') {
      Gateway.closePc();
    }
    if (mode === 'pc') {
      LocalHdc.close();
    }
  }

  private static closePc(): void {
  }

  private static context(): common.UIAbilityContext | null {
    return Gateway.ctx;
  }

  /** 判定当前该用哪条通道 */
  static async resolve(force: boolean): Promise<string> {
    if (!force && Gateway.active !== 'none' && Date.now() - Gateway.checkedAt < 60000) {
      return Gateway.active;
    }
    Gateway.checkedAt = Date.now();
    if (Gateway.mode === 'local') {
      Gateway.active = 'local';
      Gateway.pcOk = false;
      return 'local';
    }
    if (Gateway.mode === 'pc') {
      Gateway.active = 'pc';
      Gateway.pcOk = true;
      return 'pc';
    }
    const h: HealthInfo | null = await Broker.health();
    if (h !== null && h.ok === true) {
      Gateway.pcOk = true;
      Gateway.active = 'pc';
      return 'pc';
    }
    Gateway.pcOk = false;
    Gateway.active = 'local';
    return 'local';
  }

  static async health(): Promise<HealthInfo | null> {
    const ch: string = await Gateway.resolve(false);
    if (ch === 'pc') {
      const h: HealthInfo | null = await Broker.health();
      Gateway.pcOk = h !== null;
      if (h !== null) {
        return h;
      }
      Gateway.active = 'local';
    }
    const ctx: common.UIAbilityContext | null = Gateway.context();
    if (ctx === null) {
      Gateway.lastError = '缺少上下文';
      return null;
    }
    let ok: boolean = false;
    try {
      // 已存活就复用，绝不在 exec 进行中另起一次握手（那会把在途请求的回包冲掉）
      ok = LocalHdc.isAlive() ? true : await LocalHdc.connectLocked(ctx, false);
    } catch (e) {
      Gateway.lastError = '本机连接异常：' + (e as Error).message;
      LocalHdc.close();
      ok = false;
    }
    Gateway.localOk = ok;
    if (!ok) {
      if (LocalHdc.lastError.length > 0) {
        Gateway.lastError = LocalHdc.lastError;
      }
      if (Gateway.lastError.length === 0) {
        Gateway.lastError = '本机 hdcd 不可达';
      }
      Gateway.active = 'none';
      return null;
    }
    Gateway.active = 'local';
    if (Gateway.infoCache !== null) {
      return Gateway.infoCache;
    }
    let sn: string = '';
    try {
      const r: string = await LocalHdc.exec(ctx,
        'echo @@1@@; param get const.product.sn; echo @@2@@; param get const.product.model', 15000);
      const i2: number = r.indexOf('@@2@@');
      const i1: number = r.indexOf('@@1@@');
      let snRaw: string = i1 >= 0 ? r.substring(i1 + 5, i2 >= 0 ? i2 : r.length) : '';
      let mdRaw: string = i2 >= 0 ? r.substring(i2 + 5) : '';
      snRaw = snRaw.trim();
      mdRaw = mdRaw.trim();
      if (snRaw.length > 0 && snRaw.indexOf('fail') < 0 && snRaw.indexOf('errNum') < 0) {
        sn = snRaw;
      }
      if (sn.length === 0 && mdRaw.length > 0 && mdRaw.indexOf('fail') < 0 &&
        mdRaw.indexOf('errNum') < 0) {
        // uid 2000 读不到 SN，退回显示本机型号
        sn = '本机 · ' + mdRaw;
      }
    } catch (e) {
    }
    if (sn.length === 0) {
      sn = '127.0.0.1';
    }
    const info: HealthInfo = { ok: true, sn: sn, version: 'local', hdc: '127.0.0.1' };
    Gateway.infoCache = info;
    return info;
  }

  static async exec(cmd: string, timeout: number = 20000, endMark: string = ''): Promise<ExecResult> {
    const ch: string = await Gateway.resolve(false);
    if (ch === 'pc') {
      const r: ExecResult = await Broker.exec(cmd, timeout);
      if (r.code !== -1) {
        return r;
      }
      Gateway.modDropToLocal();
    }
    const ctx: common.UIAbilityContext | null = Gateway.context();
    if (ctx === null) {
      const fail: ExecResult = { code: -1, out: '', err: '缺少上下文' };
      return fail;
    }
    try {
      const out: string = await LocalHdc.exec(ctx, cmd, timeout, endMark);
      const ok: ExecResult = { code: 0, out: out, err: '' };
      return ok;
    } catch (e) {
      const m: string = (e as Error).message;
      Gateway.lastError = m;
      const fail: ExecResult = { code: -1, out: '', err: m };
      return fail;
    }
  }

  /** 大输出命令统一带结束标记：收到哨兵就立刻返回，不靠空闲窗口猜，避免白等与截断 */
  static async execMarked(cmd: string, timeout: number = 20000): Promise<ExecResult> {
    return await Gateway.exec(cmd + '; echo; echo @@SPEND@@', timeout, '@@SPEND@@');
  }

  private static modDropToLocal(): void {
    if (Gateway.mode === 'auto') {
      Gateway.active = 'local';
    }
  }

  // ---------- 能力封装（与 Broker 同名，UI 无感切换） ----------

  static async identify(): Promise<string> {
    const r: ExecResult = await Gateway.exec('id; param get const.product.model 2>/dev/null');
    return r.code === 0 ? r.out.trim() : (r.err.length > 0 ? r.err.trim() : ('exit ' + r.code));
  }

  static async capture(width: number = 1600, height: number = 0): Promise<string> {
    const shot: string = '/data/local/tmp/.sp_shot.jpeg';
    const exp: number = width <= 0 ? -1 : Math.max(600, width);
    // snapshot_display 的 -w/-h 是独立生效的：只给宽度会把高度留在原值，画面被压扁。
    // 不指定高度时按屏幕真实比例推导行高。
    let dw: number = 2800;
    let dh: number = 1840;
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      if (d.width > 0 && d.height > 0) {
        dw = d.width;
        dh = d.height;
      }
    } catch (e) {
    }
    const wPx: number = exp < 0 ? dw : exp;
    const hPx: number = height > 0 ? Math.max(400, height) : Math.round(wPx * dh / dw);
    const geo: string = exp < 0 && height <= 0
      ? '' : (' -w ' + String(wPx) + ' -h ' + String(hPx));
    for (let attempt = 0; attempt < 3; attempt++) {
      const r: ExecResult = await Gateway.exec(
        'rm -f ' + shot + '; snapshot_display' + geo + ' -f ' + shot + ' >/dev/null 2>&1; ' +
          'echo @@SZ@@; stat -c %s ' + shot + ' 2>/dev/null || wc -c < ' + shot + '; echo @@END@@',
        30000, '@@END@@');
      if (r.code !== 0) {
        continue;
      }
      const i1: number = r.out.indexOf('@@SZ@@');
      const szRaw: string = i1 >= 0 ? r.out.substring(i1 + 6).trim() : '';
      const size: number = Number.parseInt(szRaw, 10);
      if (!(size > 1024)) {
        continue;
      }
      const b64: string = await Gateway.pullBase64(shot, size);
      if (b64.length > 0) {
        return b64;
      }
      console.info('[SP-GW] 截屏校验失败，重试 ' + String(attempt + 1));
    }
    return '';
  }

  /** 取回文件的 base64；expectSize 已知时严格校验长度，长度不符视为传输截断并重试 */
  static async pullBase64(remotePath: string, expectSize: number = 0): Promise<string> {
    const ch: string = await Gateway.resolve(false);
    if (ch === 'pc') {
      const b: string = await Broker.pullBase64(remotePath);
      if (b.length > 0) {
        return b;
      }
      Gateway.modDropToLocal();
    }
    const want: number = expectSize > 0 ? Math.ceil(expectSize / 3) * 4 : 0;
    for (let attempt = 0; attempt < 2; attempt++) {
      const r: ExecResult = await Gateway.exec(
        'base64 -w 0 "' + remotePath + '" 2>&1; echo; echo @@B64@@',
        expectSize > 262144 ? 90000 : 60000, '@@B64@@');
      if (r.code !== 0) {
        continue;
      }
      let txt: string = r.out.split('\n').join('').split('\r').join('').trim();
      if (txt.indexOf('No such') >= 0 || txt.indexOf('Permission denied') >= 0) {
        return '';
      }
      if (want > 0 && txt.length !== want) {
        console.info('[SP-GW] base64 长度不符 ' + String(txt.length) + ' != ' + String(want) + '，重试');
        continue;
      }
      if (txt.length > 0 && txt.indexOf('=') === 0) {
        continue;
      }
      return txt;
    }
    return '';
  }

  static async pushBase64(remotePath: string, b64: string, timeout: number = 90000): Promise<boolean> {
    const ch: string = await Gateway.resolve(false);
    if (ch === 'pc') {
      const ok: boolean = await Broker.push(remotePath, b64, timeout);
      if (ok) {
        return true;
      }
      Gateway.modDropToLocal();
    }
    const tmp: string = remotePath + '.spb64';
    await Gateway.exec('rm -f "' + tmp + '"', 15000);
    const chunk: number = 3000;
    for (let i = 0; i < b64.length; i += chunk) {
      const piece: string = b64.substring(i, Math.min(i + chunk, b64.length));
      const r: ExecResult = await Gateway.exec("printf '%s' '" + piece + "' >> \"" + tmp + '"', 20000);
      if (r.code !== 0) {
        return false;
      }
    }
    const r2: ExecResult = await Gateway.exec(
      'base64 -d "' + tmp + '" > "' + remotePath + '" && rm -f "' + tmp + '"', 30000);
    return r2.code === 0;
  }

  static async tap(x: number, y: number): Promise<ExecResult> {
    return Gateway.exec('uitest uiInput click ' + Math.round(x) + ' ' + Math.round(y), 15000);
  }

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
    return Gateway.exec('uitest uiInput swipe ' + Math.round(x1) + ' ' + Math.round(y1) + ' '
      + Math.round(x2) + ' ' + Math.round(y2) + ' ' + v, 15000);
  }

  static async keyEvent(name: string): Promise<ExecResult> {
    return Gateway.exec('uitest uiInput keyEvent ' + name, 15000);
  }

  static async processText(): Promise<ExecResult> {
    return Gateway.execMarked('ps -ef', 20000);
  }

  static parseProcess(text: string): ProcessItem[] {
    return Broker.parseProcess(text);
  }

  static async listDir(path: string): Promise<ExecResult> {
    // 大目录的 ls 输出可能上百 KB：带哨兵，避免多等 2.5 秒或被截断
    return Gateway.execMarked('ls -lA "' + path + '" 2>&1', 30000);
  }

  static async readFile(path: string): Promise<ExecResult> {
    return Gateway.execMarked('cat "' + path + '" 2>&1', 30000);
  }

  static async writeFile(path: string, content: string): Promise<ExecResult> {
    const safe: string = content.split("'").join("'\\''");
    return Gateway.exec("printf '%s' '" + safe + "' > \"" + path + '" 2>&1', 20000);
  }

  static async removeFile(path: string): Promise<ExecResult> {
    return Gateway.exec('rm -f "' + path + '" 2>&1', 10000);
  }

  static async killProcess(pid: number): Promise<ExecResult> {
    return Gateway.exec('kill -9 ' + pid + ' 2>&1', 15000);
  }

  static async uninstall(bundle: string): Promise<ExecResult> {
    return Gateway.exec('bm uninstall -n "' + bundle + '" 2>&1', 30000);
  }

  static async startApp(bundle: string): Promise<ExecResult> {
    return Gateway.exec('aa start -a EntryAbility -b "' + bundle + '" 2>&1 || aa start -b "' + bundle + '"', 20000);
  }

  static async appList(): Promise<ExecResult> {
    // bm dump -a -l 在装满应用的机器上能到几百 KB，必须带哨兵
    return Gateway.execMarked('bm dump -a -l', 90000);
  }

  static async deviceInfo(): Promise<ExecResult> {
    return Gateway.execMarked(
      'echo model=$(param get const.product.model); ' +
      'echo brand=$(param get const.product.brand); ' +
      'echo api=$(param get const.ohos.apiversion); ' +
      'echo ver=$(param get const.product.software.version)', 20000);
  }
}
