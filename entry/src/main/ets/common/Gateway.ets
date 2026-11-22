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

  /**
   * 把外部传进来的路径 / 包名安全地包成 shell 参数。
   * 之前统一用双引号拼："... \" + path + '\"'，参数里出现一个 " 或 $ 就把命令拼歪，
   * 甚至能让 cat/ls 变成执行别的语句。这里统一走单引号 + 转义。
   */
  private static q(s: string): string {
    return "'" + s.split("'").join("'\\''") + "'";
  }

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

  /** 向当前获得焦点的输入框注入文本（uid 2000 通过 uitest 实现） */
  static async inputText(text: string): Promise<ExecResult> {
    const safe: string = text.split("'").join("'\\''");
    return Gateway.exec("uitest uiInput text '" + safe + "'", 15000);
  }

  /** 仅点亮屏幕（power-shell wakeup，非切换，比 Power 键稳） */
  static async wake(): Promise<ExecResult> {
    return Gateway.exec('power-shell wakeup 2>&1', 15000);
  }

  /** 本机保存的锁屏 PIN：只在本进程内使用，任何 API 入参都不接受 PIN */
  static localPin(): string {
    const c: common.UIAbilityContext | null = Gateway.ctx;
    if (c === null) {
      return '';
    }
    try {
      const store = preferences.getPreferencesSync(c, { name: PREFS });
      return store.getSync('unlockPin', '') as string;
    } catch (e) {
      return '';
    }
  }

  /** 从屏幕中部上滑（用于锁屏露出 PIN 键盘） */
  static async swipeUp(w: number, h: number): Promise<ExecResult> {
    return Gateway.exec('uitest uiInput swipe ' + Math.round(w * 0.5) + ' ' + Math.round(h * 0.54)
      + ' ' + Math.round(w * 0.5) + ' ' + Math.round(h * 0.24) + ' 12000', 15000);
  }

  /**
   * 一键解锁：亮屏 → 中部上滑 → 按 PIN 点数字键。
   * 整条序列放进一次 shell 里跑，避免每条命令单独起进程把屏幕拖黑。
   * 键盘坐标按真机实测比例换算（2800×1840 下三列 x=0.394/0.5/0.605，
   * 三行 y=0.421/0.566/0.712，0 键 y=0.857）。
   */
  static async unlock(pin: string, wakeDelayMs: number, gapMs: number,
                      w: number, h: number, offFirst: boolean = false): Promise<ExecResult> {
    const p: string = pin.split("'").join('');
    if (p.length === 0) {
      return Gateway.exec('echo no-pin', 10000);
    }
    const delay: number = wakeDelayMs > 0 ? Math.min(wakeDelayMs, 5000) / 1000 : 0.8;
    const gap: number = gapMs > 0 ? Math.min(gapMs, 2000) / 1000 : 0.3;
    const ds: string = delay.toFixed(2);
    const gs: string = gap.toFixed(2);
    let cmd: string = '';
    if (offFirst) {
      // 测试用：先用 Power 把屏按灭，等锁屏状态稳定，再走完整解锁序列
      cmd = 'uitest uiInput keyEvent Power >/dev/null 2>&1; sleep 1.2; ';
    }
    cmd += 'power-shell wakeup >/dev/null 2>&1; sleep ' + ds
      + '; uitest uiInput swipe ' + Math.round(w * 0.5) + ' ' + Math.round(h * 0.54)
      + ' ' + Math.round(w * 0.5) + ' ' + Math.round(h * 0.24) + ' 12000 >/dev/null 2>&1; sleep 0.55';
    for (let i = 0; i < p.length; i++) {
      const ch: string = p.charAt(i);
      let cx: number = 0.5;
      let cy: number = 0.857;
      if (ch === '1' || ch === '4' || ch === '7') {
        cx = 0.394;
      } else if (ch === '3' || ch === '6' || ch === '9') {
        cx = 0.605;
      }
      if (ch === '1' || ch === '2' || ch === '3') {
        cy = 0.421;
      } else if (ch === '4' || ch === '5' || ch === '6') {
        cy = 0.566;
      } else if (ch === '7' || ch === '8' || ch === '9') {
        cy = 0.712;
      }
      cmd += '; uitest uiInput click ' + Math.round(w * cx) + ' ' + Math.round(h * cy)
        + ' >/dev/null 2>&1; sleep ' + gs;
    }
    cmd += '; echo @@SPUNLOCK@@';
    return Gateway.exec(cmd, 30000, '@@SPUNLOCK@@');
  }

  /** 导出当前界面布局树（uitest dumpLayout），返回 JSON 原文 */
  static async dumpUi(): Promise<ExecResult> {
    const p: string = '/data/local/tmp/.sp_ui.json';
    const prep: ExecResult = await Gateway.exec(
      'rm -f ' + p + '; uitest dumpLayout -p ' + p + ' >/dev/null 2>&1; ' +
        'echo @@SZ@@; stat -c %s ' + p + ' 2>/dev/null; echo @@END@@',
      30000, '@@END@@');
    if (prep.code !== 0) {
      return prep;
    }
    const i: number = prep.out.indexOf('@@SZ@@');
    const szRaw: string = i >= 0 ? prep.out.substring(i + 6).trim() : '';
    const size: number = Number.parseInt(szRaw, 10);
    if (!(size > 0)) {
      const fail: ExecResult = { code: -1, out: '', err: '布局导出失败' };
      return fail;
    }
    return await Gateway.readFile(p);
  }

  /** netstat 全量套接字（uid 2000 读不了 /proc/net/tcp，但 netstat 可以） */
  static async sockets(): Promise<ExecResult> {
    return Gateway.execMarked('netstat -an 2>&1', 20000);
  }

  /** 单个应用的完整 bundle 信息（bm dump -n），含权限、UID、主 Ability */
  static async appDetail(bundle: string): Promise<ExecResult> {
    return Gateway.execMarked('bm dump -n "' + bundle + '" 2>&1', 30000);
  }

  /** 安装 HAP（必须已签名；replace=true 覆盖安装） */
  static async install(path: string, replace: boolean): Promise<ExecResult> {
    return Gateway.exec('bm install ' + (replace ? '-r ' : '') + '-p ' + Gateway.q(path) + ' 2>&1', 60000);
  }

  /** 强停应用（kill -9 对非本 uid 进程无效，这条才管用） */
  static async forceStop(bundle: string): Promise<ExecResult> {
    return Gateway.exec('aa force-stop ' + Gateway.q(bundle) + ' 2>&1', 15000);
  }

  /** 系统参数里 uid 2000 可读的那几个 */
  static async sysParams(): Promise<ExecResult> {
    return Gateway.execMarked(
      'for p in const.product.brand const.product.model const.product.name ' +
        'const.ohos.apiversion const.product.software.version const.product.cpu.abilist; ' +
        'do echo "$p=$(param get $p 2>/dev/null)"; done', 20000);
  }

  static async storage(): Promise<ExecResult> {
    return Gateway.execMarked('df -h /data 2>&1', 20000);
  }

  static async topSnapshot(): Promise<ExecResult> {
    return Gateway.execMarked('top -n 1 2>&1', 30000);
  }

  /** 设备 UDID（bm get -u，uid 2000 可读，比 param get sn 可靠） */
  static async udid(): Promise<ExecResult> {
    return Gateway.exec('bm get -u 2>&1', 20000);
  }

  /** 清指定应用的缓存（mode=data 时才清数据，默认只清缓存） */
  static async cleanBundle(bundle: string, mode: string): Promise<ExecResult> {
    const flag: string = mode === 'data' ? '-d' : '-c';
    return Gateway.exec('bm clean -n ' + Gateway.q(bundle) + ' ' + flag + ' 2>&1', 30000);
  }

  /** 系统事件历史（hisysevent）：可查崩溃、性能、安全、行为四类 */
  static async sysEvents(type: string, domain: string, name: string, count: number): Promise<ExecResult> {
    let cmd: string = 'hisysevent -l';
    if (type.length > 0) {
      cmd += ' -g ' + Gateway.q(type);
    }
    if (domain.length > 0) {
      cmd += ' -o ' + Gateway.q(domain);
    }
    if (name.length > 0) {
      cmd += ' -n ' + Gateway.q(name);
    }
    const n: number = count > 0 ? Math.min(count, 500) : 20;
    cmd += ' -m ' + String(n);
    return Gateway.execMarked(cmd + ' 2>&1', 30000);
  }

  /** 日志缓冲区尾部 N 行（hilog -x -z） */
  static async hilogTail(count: number): Promise<ExecResult> {
    const n: number = count > 0 ? Math.min(count, 2000) : 200;
    return Gateway.execMarked('hilog -x -z ' + String(n) + ' 2>&1', 30000);
  }

  /** 崩溃/异常退出记录列表（hidumper -e --list，绕开被拒的 /data/log） */
  static async crashList(): Promise<ExecResult> {
    return Gateway.execMarked('hidumper -e --list 2>&1', 30000);
  }

  /** 按 record_id 读崩溃日志全文（含设备信息、堆栈） */
  static async crashDetail(id: string): Promise<ExecResult> {
    let safe: string = '';
    for (let i = 0; i < id.length; i++) {
      const c: string = id.charAt(i);
      if (c >= '0' && c <= '9') {
        safe += c;
      }
    }
    if (safe.length === 0) {
      return Gateway.exec('echo no-record-id', 10000);
    }
    return Gateway.execMarked('hidumper -e --print ' + safe + ' 2>&1', 30000);
  }

  /**
   * F-01 双路径对照：直接访问崩溃日志目录，预期被 DAC 拒绝。
   * 只做 ls，不读正文，用于和 crashList / crashDetail 形成对照证据。
   */
  static async catFaultlogDenied(): Promise<ExecResult> {
    return Gateway.execMarked('ls -l /data/log/faultlog/faultlogger 2>&1 | head -3', 20000);
  }

  /** 全进程内存明细：Pss/Vss/Rss/Uss/GL/Graph（hidumper --mem） */
  static async memDump(): Promise<ExecResult> {
    return Gateway.execMarked('hidumper --mem 2>&1', 45000);
  }

  /** 全局 CPU 负载 + 进程占用（hidumper --cpuusage） */
  static async cpuDump(): Promise<ExecResult> {
    return Gateway.execMarked('hidumper --cpuusage 2>&1', 30000);
  }

  /** 网卡信息：IP / MAC / 收发字节 / 丢包（ifconfig） */
  static async ifaces(): Promise<ExecResult> {
    return Gateway.execMarked('ifconfig 2>&1', 20000);
  }

  /** 全局网络流量（hidumper --net） */
  static async netTraffic(): Promise<ExecResult> {
    return Gateway.execMarked('hidumper --net 2>&1', 30000);
  }

  /** 单进程详情：线程、FD、挂载（hidumper -p pid） */
  static async procDetail(pid: number): Promise<ExecResult> {
    return Gateway.execMarked('hidumper -p ' + Math.round(pid) + ' 2>&1', 30000);
  }

  /** 每核实时频率（hidumper --cpufreq） */
  static async cpuFreq(): Promise<ExecResult> {
    return Gateway.execMarked('hidumper --cpufreq 2>&1', 20000);
  }

  /** 系统基础信息集群：BuildId / OsVersion / 机型（hidumper -c base） */
  static async sysCluster(): Promise<ExecResult> {
    return Gateway.execMarked('hidumper -c base 2>&1', 30000);
  }

  /** 全系统 HSP 共享库清单（bm dump-shared -a） */
  static async sharedLibs(): Promise<ExecResult> {
    return Gateway.execMarked('bm dump-shared -a 2>&1', 30000);
  }

  /** 某应用的补丁(quickfix)状态（bm quickfix -q -b） */
  static async quickFix(bundle: string): Promise<ExecResult> {
    return Gateway.execMarked('bm quickfix -q -b ' + Gateway.q(bundle) + ' 2>&1', 30000);
  }

  /**
   * 用 shell 里的 openssl 直接发 HTTPS 请求（uid 2000 有 netsys_socket 组，网络可用）。
   * 只允许字母数字和少量 URL 字符，避免命令注入。
   */
  static async httpFetch(url: string): Promise<ExecResult> {
    let u: string = url;
    if (u.startsWith('https://')) {
      u = u.substring(8);
    } else if (u.startsWith('http://')) {
      u = u.substring(7);
    }
    let hostPort: string = u;
    let path: string = '/';
    const slash: number = u.indexOf('/');
    if (slash >= 0) {
      hostPort = u.substring(0, slash);
      path = u.substring(slash);
    }
    let host: string = hostPort;
    let port: string = '443';
    const colon: number = hostPort.indexOf(':');
    if (colon > 0) {
      host = hostPort.substring(0, colon);
      port = hostPort.substring(colon + 1);
    }
    const okChars: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_';
    for (let i = 0; i < host.length; i++) {
      if (!okChars.includes(host.charAt(i))) {
        return Gateway.exec('echo bad-host', 10000);
      }
    }
    const okPort: string = '0123456789';
    for (let i = 0; i < port.length; i++) {
      if (!okPort.includes(port.charAt(i))) {
        return Gateway.exec('echo bad-port', 10000);
      }
    }
    const okPath: string = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_/?=&%';
    let safePath: string = '';
    for (let i = 0; i < path.length; i++) {
      const c: string = path.charAt(i);
      if (okPath.includes(c)) {
        safePath += c;
      }
    }
    if (safePath.length === 0) {
      safePath = '/';
    }
    if (port === '80') {
      // 明文 HTTP 走不了 s_client，这里统一按 443 处理会失败，直接提示
      return Gateway.exec('echo only-https', 10000);
    }
    const cmd: string = "echo -e 'GET " + safePath + " HTTP/1.0\\r\\nHost: " + host
      + "\\r\\nUser-Agent: StarPivot\\r\\nConnection: close\\r\\n\\r\\n'"
      + ' | openssl s_client -quiet -connect ' + host + ':' + port + ' 2>/dev/null | head -c 20000';
    return Gateway.execMarked(cmd, 30000);
  }

  static async processText(): Promise<ExecResult> {
    return Gateway.execMarked('ps -ef', 20000);
  }

  static parseProcess(text: string): ProcessItem[] {
    return Broker.parseProcess(text);
  }

  static async listDir(path: string): Promise<ExecResult> {
    // 大目录的 ls 输出可能上百 KB：带哨兵，避免多等 2.5 秒或被截断
    return Gateway.execMarked('ls -lA ' + Gateway.q(path) + ' 2>&1', 30000);
  }

  static async readFile(path: string): Promise<ExecResult> {
    return Gateway.execMarked('cat ' + Gateway.q(path) + ' 2>&1', 30000);
  }

  static async writeFile(path: string, content: string): Promise<ExecResult> {
    return Gateway.exec('printf %s ' + Gateway.q(content) + ' > ' + Gateway.q(path) + ' 2>&1', 20000);
  }

  static async removeFile(path: string): Promise<ExecResult> {
    return Gateway.exec('rm -f ' + Gateway.q(path) + ' 2>&1', 10000);
  }

  static async killProcess(pid: number): Promise<ExecResult> {
    return Gateway.exec('kill -9 ' + pid + ' 2>&1', 15000);
  }

  static async uninstall(bundle: string): Promise<ExecResult> {
    return Gateway.exec('bm uninstall -n ' + Gateway.q(bundle) + ' 2>&1', 30000);
  }

  static async startApp(bundle: string): Promise<ExecResult> {
    // aa start 只给 -b 会报"找不到可隐式启动的应用"，必须带 -a 主 Ability。
    // 主 Ability 名从 bundle dump 里的 "mainAbility" 字段取，取不到再退回 EntryAbility。
    let ab: string = '';
    try {
      const d: ExecResult = await Gateway.execMarked('bm dump -n ' + Gateway.q(bundle) + ' 2>/dev/null', 30000);
      const key: string = '"mainAbility": "';
      const i: number = d.out.indexOf(key);
      if (i >= 0) {
        const j: number = d.out.indexOf('"', i + key.length);
        if (j > i) {
          ab = d.out.substring(i + key.length, j);
        }
      }
    } catch (e) {
    }
    if (ab.length === 0) {
      ab = 'EntryAbility';
    }
    return Gateway.exec('aa start -a ' + ab + ' -b ' + Gateway.q(bundle) + ' 2>&1', 20000);
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
