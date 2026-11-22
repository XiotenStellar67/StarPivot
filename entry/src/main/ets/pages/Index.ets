import { common, bundleManager } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ApiServer } from '../common/ApiServer';
import { ExecResult, ProcessItem } from '../common/Broker';
import { Gateway } from '../common/Gateway';
import { LocalHdc } from '../common/LocalHdc';
import { display } from '@kit.ArkUI';

interface FileItem {
  name: string;
  isDir: boolean;
  size: string;
  mode: string;
}

interface AppEntry {
  bundleName: string;
  label: string;
}

interface DfxCase {
  label: string;
  cmd: string;
  timeout: number;
}

// 主题色：深灰 × 金黄（XS UI 规格）—— 运行期可被「外观设置」改写，所以用 let
let BG: string = '#26262A';
let BG_DEEP: string = '#1F1F22';
let CARD: string = '#333338';
let CARD2: string = '#3D3D44';
let ACCENT: string = '#FFC400';
let ACCENT_DIM: string = '#D9A400';
let ACCENT_SOFT: string = '#3A3418';
let OKC: string = '#FFC400';
let WARN: string = '#A9A9B2';
let TEXT: string = '#F2F2F4';
let MUTED: string = '#A9A9B2';
let LINE: string = '#4A4A52';
let ON_ACCENT: string = '#26262A';
let DEL_BG: string = '#5A2A28';
let DEL_TX: string = '#F2F2F4';
/** 字号缩放：外观设置里的字体大小 */
let FS: number = 1;

function fsz(n: number): number {
  return Math.round(n * FS * 10) / 10;
}

function hexToRgb(s: string): number[] {
  const h: string = s.startsWith('#') ? s.substring(1) : s;
  const r: number = Number.parseInt(h.substring(0, 2), 16);
  const g: number = Number.parseInt(h.substring(2, 4), 16);
  const b: number = Number.parseInt(h.substring(4, 6), 16);
  return [r, g, b];
}

function rgbToHex(r: number, g: number, b: number): string {
  const clamp = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));
  const h2 = (v: number): string => {
    const t: string = clamp(v).toString(16);
    return t.length === 1 ? ('0' + t) : t;
  };
  return '#' + h2(r) + h2(g) + h2(b);
}

/** 让颜色向白/黑偏移一个固定量，用来从背景色推导卡片、描边等层级 */
function shift(s: string, delta: number): string {
  const c: number[] = hexToRgb(s);
  return rgbToHex(c[0] + delta, c[1] + delta, c[2] + delta);
}

interface BgPreset {
  name: string;
  bg: string;
  deep: string;
}

interface AccPreset {
  name: string;
  color: string;
}

const BG_PRESETS: BgPreset[] = [
  { name: '深灰', bg: '#26262A', deep: '#1F1F22' },
  { name: '纯黑', bg: '#111114', deep: '#0B0B0D' },
  { name: '深蓝', bg: '#1B2333', deep: '#151B28' },
  { name: '墨绿', bg: '#1B2621', deep: '#151E1A' },
  { name: '暖褐', bg: '#2A2422', deep: '#211C1A' }
];

const ACC_PRESETS: AccPreset[] = [
  { name: '金黄', color: '#FFC400' },
  { name: '青碧', color: '#33D1C6' },
  { name: '天蓝', color: '#5AA8FF' },
  { name: '品红', color: '#FF7AB6' },
  { name: '草绿', color: '#8ED65C' },
  { name: '橙红', color: '#FF8A4C' }
];

function applyThemeColors(bgIdx: number, accIdx: number): void {
  const bp: BgPreset = BG_PRESETS[bgIdx >= 0 && bgIdx < BG_PRESETS.length ? bgIdx : 0];
  const ap: AccPreset = ACC_PRESETS[accIdx >= 0 && accIdx < ACC_PRESETS.length ? accIdx : 0];
  BG = bp.bg;
  BG_DEEP = bp.deep;
  CARD = shift(bp.bg, 13);
  CARD2 = shift(bp.bg, 23);
  LINE = shift(bp.bg, 44);
  ACCENT = ap.color;
  OKC = ap.color;
  ACCENT_DIM = shift(ap.color, -30);
  ACCENT_SOFT = shift(bp.bg, 34);
  ON_ACCENT = '#1A1A1C';
  const c: number[] = hexToRgb(ap.color);
  // 高亮色偏亮时，其上文字用深色；偏暗时用浅色
  const lum: number = (c[0] * 299 + c[1] * 587 + c[2] * 114) / 1000;
  ON_ACCENT = lum > 150 ? '#17171A' : '#F7F7F8';
  DEL_BG = shift(BG, 20);
  DEL_TX = TEXT;
}

@Entry
@Component
struct Index {
  @State curTab: number = 0;
  /** 「功能」页内的子页选择：0 屏幕 / 1 进程 / 2 文件 / 3 应用 / 4 解锁 / 5 诊断 / 6 终端 */
  @State funcSel: number = 0;
  /** 功能页侧栏宽度：按窗口宽度自适应（手机窄、平板宽），旋转/分屏时同步变化 */
  @State sideW: number = 132;
  /** 从 bundleManager 读取的真实版本串，界面上不再硬编码 */
  @State appVer: string = '';

  // ---- 终端页 ----
  @State termCmd: string = '';
  @State termOut: string = '';
  @State termHist: string[] = [];
  @State termCwd: string = '/data/local/tmp';
  @State termBusy: boolean = false;
  @State termMsg: string = '';
  @State brokerOk: boolean = false;
  @State channel: string = '未连接';
  @State hdcPort: string = '';
  @State connMode: string = 'auto';
  @State sn: string = '未连接';
  @State hdcPath: string = '';
  @State logs: string[] = [];
  @State ident: string = '';
  @State devInfo: string = '';

  @State shot: string = '';
  @State tapX: string = '400';
  @State tapY: string = '1200';
  @State swipeX1: string = '400';
  @State swipeY1: string = '1500';
  @State swipeX2: string = '400';
  @State swipeY2: string = '600';
  @State screenMsg: string = '';
  @State shotW: string = '1600';
  @State shotH: string = '0';
  @State showSettings: boolean = false;
  @State bgIdx: number = 0;
  @State accIdx: number = 0;
  @State fontStep: number = 1;
  @State animOn: boolean = true;
  @State themeRev: number = 0;
  @State pageAlpha: number = 1;

  @State processes: ProcessItem[] = [];
  @State procMsg: string = '';

  @State dirPath: string = '/data/local/tmp';
  @State dirText: string = '';
  @State fileItems: FileItem[] = [];
  @State filePath: string = '/data/local/tmp/starpivot_note.txt';
  @State fileContent: string = '';
  @State fileMsg: string = '';
  @State fileKind: string = 'text';
  @State fileImage: string = '';
  @State fileInfo: string = '';
  @State searchKey: string = '';
  @State searchMsg: string = '';
  @State searchHits: string[] = [];

  @State bundle: string = '';
  @State appMsg: string = '';
  @State appText: string = '';
  @State apps: AppEntry[] = [];
  @State appFilter: string = '';
  @State appPicked: string = '';

  @State apiOn: boolean = false;
  @State apiPort: string = '18790';
  /** /v1/shell 是否对第三方应用开放，默认关；开关状态持久化 */
  @State shellOn: boolean = false;
  @State token: string = '';
  @State apiMsg: string = '';

  @State pinText: string = '';
  @State unlockDelay: string = '800';
  @State unlockGap: string = '300';
  @State unlockMsg: string = '';
  @State offFirst: boolean = false;

  @State diagMsg: string = '';
  @State diagText: string = '';
  @State crashId: string = '';
  @State urlText: string = 'https://www.baidu.com/';

  @State f01Msg: string = '';
  @State f01Verdict: string = '';
  @State f01Text: string = '';
  @State f01Id: string = '';
  @State f01Armed: boolean = false;

  // 沙箱隔离探测（只做存在性检查）
  @State sbxBundle: string = 'com.huawei.hmos.settings';
  @State sbxResult: string = '';
  @State sbxMsg: string = '';

  // DFX 调试工具横向排查（只读）
  @State dfxText: string = '';
  @State dfxRunning: boolean = false;
  @State dfxMsg: string = '';

  private api: ApiServer = new ApiServer();

  aboutToAppear(): void {
    this.api.setLogger((m: string) => {
      this.log(m);
    });
    try {
      const hostCtx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      Gateway.init(hostCtx);
      const store = preferences.getPreferencesSync(hostCtx, { name: 'starpivot' });
      this.connMode = store.getSync('connMode', 'auto') as string;
      this.bgIdx = store.getSync('uiBg', 0) as number;
      this.accIdx = store.getSync('uiAcc', 0) as number;
      this.fontStep = store.getSync('uiFont', 1) as number;
      this.animOn = store.getSync('uiAnim', true) as boolean;
      applyThemeColors(this.bgIdx, this.accIdx);
      FS = this.fontScaleOf(this.fontStep);
    } catch (e) {
    }
    this.loadToken();
    this.restoreApi();
    this.restoreUnlock();
    this.loadVer();
    this.checkBroker();
  }

  /** 版本号从包管理器读，避免硬编码在界面里和 app.json5 对不上（上一版就停在 1.2.0） */
  private loadVer(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVer = info.versionName + ' (' + info.versionCode + ')';
    } catch (e) {
      this.appVer = '1.2.1 (1002001)';
    }
  }

  private restoreUnlock(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      this.pinText = store.getSync('unlockPin', '') as string;
      this.unlockDelay = '' + (store.getSync('unlockDelay', 800) as number);
      this.unlockGap = '' + (store.getSync('unlockGap', 300) as number);
      this.offFirst = store.getSync('unlockOffFirst', false) as boolean;
    } catch (e) {
    }
  }

  private saveUnlock(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      store.putSync('unlockPin', this.pinText);
      store.putSync('unlockDelay', Number.parseInt(this.unlockDelay) || 800);
      store.putSync('unlockGap', Number.parseInt(this.unlockGap) || 300);
      store.putSync('unlockOffFirst', this.offFirst);
      store.flush();
    } catch (e) {
    }
  }

  private async doUnlock(): Promise<void> {
    if (this.pinText.length === 0) {
      this.unlockMsg = '先填锁屏 PIN';
      return;
    }
    this.saveUnlock();
    this.unlockMsg = '执行中…';
    try {
      const d = display.getDefaultDisplaySync();
      const r: ExecResult = await Gateway.unlock(this.pinText,
        Number.parseInt(this.unlockDelay) || 800,
        Number.parseInt(this.unlockGap) || 300, d.width, d.height, this.offFirst);
      this.unlockMsg = r.code === 0 ? '已发送：亮屏 → 上滑 → PIN' : ('失败：' + r.out);
    } catch (e) {
      this.unlockMsg = '异常：' + e;
    }
  }

  private async doWake(): Promise<void> {    this.unlockMsg = '执行中…';
    try {
      const r: ExecResult = await Gateway.wake();
      this.unlockMsg = r.code === 0 ? '已点亮屏幕' : ('失败：' + r.out);
    } catch (e) {
      this.unlockMsg = '异常：' + e;
    }
  }

  private async runDiag(kind: string): Promise<void> {
    this.diagMsg = '读取中…';
    let r: ExecResult = await Gateway.memDump();
    if (kind === 'mem') {
      r = await Gateway.memDump();
    } else if (kind === 'cpu') {
      r = await Gateway.cpuDump();
    } else if (kind === 'crash') {
      r = await Gateway.crashList();
    } else if (kind === 'iface') {
      r = await Gateway.ifaces();
    } else if (kind === 'traffic') {
      r = await Gateway.netTraffic();
    } else if (kind === 'cpufreq') {
      r = await Gateway.cpuFreq();
    } else if (kind === 'cluster') {
      r = await Gateway.sysCluster();
    } else if (kind === 'shared') {
      r = await Gateway.sharedLibs();
    } else if (kind === 'http') {
      r = await Gateway.httpFetch(this.urlText);
    } else {
      r = await Gateway.crashDetail(this.crashId);
    }
    this.diagText = r.out;
    this.diagMsg = r.code === 0 ? '完成' : ('失败：' + r.out);
  }

  private tokens(line: string): string[] {
    const out: string[] = [];
    let cur: string = '';
    for (let i = 0; i < line.length; i++) {
      const c: string = line.charAt(i);
      if (c === ' ' || c === '\t' || c === '\r') {
        if (cur.length > 0) {
          out.push(cur);
          cur = '';
        }
      } else {
        cur += c;
      }
    }
    if (cur.length > 0) {
      out.push(cur);
    }
    return out;
  }

  /** F-01 对照自查：直接访问被拒 vs 服务代理可读，并统计记录归属分布 */
  private async runF01(): Promise<void> {
    this.f01Msg = '自查中…';
    this.f01Text = '';
    let catOut: string = '';
    let listOut: string = '';
    const cat: ExecResult = await Gateway.catFaultlogDenied();
    catOut = cat.out;
    const list: ExecResult = await Gateway.crashList();
    listOut = list.out;

    let total: number = 0;
    let own: number = 0;
    let other: number = 0;
    let firstOtherId: string = '';
    const lines: string[] = listOut.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const tk: string[] = this.tokens(lines[i]);
      if (tk.length < 6) {
        continue;
      }
      if (tk[3] !== 'JsError' && tk[3] !== 'LowMemoryKill' && tk[3] !== 'AppFreeze'
        && tk[3] !== 'CppCrash' && tk[3] !== 'ProcessExit') {
        continue;
      }
      total++;
      if (tk[5].startsWith('com.starpivot.xs')) {
        own++;
      } else {
        other++;
        if (firstOtherId.length === 0) {
          firstOtherId = tk[4];
        }
      }
    }

    const catDenied: boolean = catOut.indexOf('Permission denied') >= 0;
    let verdict: string = '';
    if (catDenied && total > 0) {
      verdict = '结论：两条路径策略不一致\n'
        + '· 直接访问 /data/log/faultlog/faultlogger → Permission denied\n'
        + '· hidumper -e --list → 可列 ' + total + ' 条记录（其中非本应用 ' + other + ' 条）\n'
        + '· 同一份数据，一条路径被拒、另一条被允许';
    } else if (!catDenied) {
      verdict = '对照组未得到 Permission denied，本机策略与此前不同，结论不成立。';
    } else {
      verdict = '目录已被拒，但未列出任何崩溃记录，无法形成对照。';
    }
    this.f01Verdict = verdict;
    this.f01Msg = '本应用记录 ' + own + ' 条；非本应用记录 ' + other
      + ' 条（默认不读取，如需取证请手动确认后填入 record_id）';
  }

  /** 单条记录读取：需开关已确认，只在本机屏幕显示 */
  private async runF01Read(): Promise<void> {
    if (!this.f01Armed) {
      return;
    }
    this.f01Text = '读取中…';
    const r: ExecResult = await Gateway.crashDetail(this.f01Id);
    let out: string = r.out;
    if (out.length > 2200) {
      out = out.substring(0, 2200) + '\n…（已截断）';
    }
    this.f01Text = out;
  }

  /**
   * DFX 用例判定：只按输出特征分类，不解析内容、不保存内容。
   * 拒绝 = 明确的权限拒绝特征；空正文 = 有表头无内容；有数据 = 返回了正文。
   */
  private dfxClassify(r: ExecResult): string {
    if (r.code === -1) {
      return '连接失败';
    }
    const merged: string = (r.out + ' ' + r.err).toLowerCase();
    if (merged.indexOf('permission denied') >= 0
      || merged.indexOf('permission check failed') >= 0
      || merged.indexOf('only supported for debug') >= 0
      || merged.indexOf('only support debug') >= 0
      || merged.indexOf('not authorized') >= 0
      || merged.indexOf('not allowed') >= 0
      || merged.indexOf('forbidden') >= 0
      || merged.indexOf('eacces') >= 0) {
      return '拒绝';
    }
    if (r.out.trim().length === 0) {
      return '空正文';
    }
    return '有数据';
  }

  /**
   * DFX 调试工具横向排查：按固定清单依次执行只读命令，
   * 只记录"被拒 / 空正文 / 有数据"和首行摘要，不落盘、不导出、不进 API 列表。
   */
  private async runDfx(): Promise<void> {
    if (this.dfxRunning) {
      return;
    }
    this.dfxRunning = true;
    this.dfxText = '';
    const cases: DfxCase[] = [
      { label: 'hidumper -ls（SystemAbility 清单）', cmd: 'hidumper -ls', timeout: 10000 },
      { label: 'hidumper --mem（全进程内存明细）', cmd: 'hidumper --mem | head -n 120', timeout: 20000 },
      { label: 'hidumper --cpuusage（全局 CPU 负载）', cmd: 'hidumper --cpuusage', timeout: 10000 },
      { label: 'hidumper --cpufreq（每核实时频率）', cmd: 'hidumper --cpufreq', timeout: 10000 },
      { label: 'hidumper --net（全局网络流量）', cmd: 'hidumper --net | head -n 120', timeout: 15000 },
      { label: 'hidumper --storage（存储信息）', cmd: 'hidumper --storage | head -n 120', timeout: 15000 },
      { label: 'hidumper --zip（zip 相关）', cmd: 'hidumper --zip | head -n 120', timeout: 12000 },
      { label: 'hidumper -p 1（单进程详情, pid=1）', cmd: 'hidumper -p 1', timeout: 10000 },
      { label: 'hidumper -s RenderService（SA 正文）', cmd: 'hidumper -s RenderService', timeout: 12000 },
      { label: 'bm dump -a（全系统应用清单）', cmd: 'bm dump -a', timeout: 15000 },
      { label: 'bm dump -n com.huawei.hmos.settings（他包详情）', cmd: 'bm dump -n com.huawei.hmos.settings | head -n 120', timeout: 15000 },
      { label: 'bm get -u（设备 UDID）', cmd: 'bm get -u', timeout: 10000 },
      { label: 'hisysevent -l -g FAULT（故障事件）', cmd: 'hisysevent -l -g FAULT', timeout: 15000 },
      { label: 'hisysevent -l -g STATISTIC（统计事件）', cmd: 'hisysevent -l -g STATISTIC', timeout: 15000 },
      { label: 'hilog -x（全局日志）', cmd: 'hilog -x', timeout: 25000 }
    ];

    let out: string = '';
    let pass: number = 0;
    let deny: number = 0;
    let other: number = 0;
    for (let i = 0; i < cases.length; i++) {
      const c: DfxCase = cases[i];
      let verdict: string = '异常';
      let head: string = '';
      let lines: number = 0;
      try {
        const r: ExecResult = await Gateway.exec(c.cmd, c.timeout);
        verdict = this.dfxClassify(r);
        const body: string = r.out.trim();
        lines = body.length === 0 ? 0 : body.split('\n').length;
        const first: string = body.length === 0 ? '(空)' : body.split('\n')[0];
        head = first.length > 56 ? first.substring(0, 56) + '…' : first;
      } catch (e) {
        verdict = '异常';
      }
      if (verdict === '有数据') {
        pass++;
      } else if (verdict === '拒绝') {
        deny++;
      } else {
        other++;
      }
      out += (i + 1) + '. ' + c.label + ' → ' + verdict + '（' + lines + ' 行）\n'
        + '    $ ' + c.cmd + '\n'
        + '    首行: ' + head + '\n';
      this.dfxText = out;
      this.dfxMsg = '已跑 ' + (i + 1) + '/' + cases.length + ' 条…';
    }

    out += '\n小结：有数据 ' + pass + ' 条 / 被拒 ' + deny + ' 条 / 空或异常 ' + other + ' 条\n';
    out += '注：仅记录"是否可读"，未保存任何输出内容，未做任何写操作。';
    this.dfxText = out;
    this.dfxMsg = '完成，共 ' + cases.length + ' 条';
    this.dfxRunning = false;
  }

  /**
   * 单个路径的只读探测：只调用 statSync 判断"能否看见"，拿到系统 errno。
   * 不 open、不 read，因此即使路径可进入也拿不到任何内容。
   */
  private probePath(label: string, path: string): string {
    try {
      fs.statSync(path);
      return label + '：可见（exist = true）\n  ' + path;
    } catch (e) {
      const err = e as BusinessError;
      const code: number = err.code;
      const msg: string = err.message === undefined ? '' : err.message;
      let kind: string = '不可访问';
      if (code === 13900002) {
        kind = '不存在（ENOENT）';
      } else if (code === 13900012) {
        kind = '被拒绝（EACCES）';
      }
      return label + '：' + kind + '\n  errno = ' + String(code) + '  ' + msg + '\n  ' + path;
    }
  }

  /**
   * 沙箱隔离探测：三组路径，只比对 errno。
   *   C1 本应用沙箱路径（可见，作为阳性对照）
   *   C2 本应用宿主路径 /data/app/el2/100/base/<自身包名>（应不可见：命名空间隔离）
   *   T  他包宿主路径（应不可见或拒绝）
   * 不读取任何文件内容，不落盘、不上传、不进 API 列表。
   */
  private async runSbx(): Promise<void> {
    const bg: string = this.sbxBundle.trim();
    if (bg.length === 0) {
      this.sbxMsg = '请先填写目标包名';
      return;
    }
    let safeBg: string = '';
    for (let i = 0; i < bg.length; i++) {
      const c: string = bg.charAt(i);
      const okChar: boolean = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c === '.' || c === '_';
      if (okChar) {
        safeBg += c;
      }
    }
    if (safeBg.length === 0) {
      this.sbxMsg = '包名只允许字母、数字、点、下划线';
      return;
    }

    this.sbxMsg = '探测中…';
    this.sbxResult = '';

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const ownDir: string = ctx.preferencesDir.length > 0 ? ctx.preferencesDir : (ctx.filesDir + '/preferences');
    const ownBundle: string = ctx.applicationInfo.name;
    const ownHost: string = '/data/app/el2/100/base/' + ownBundle;
    const foreignBase: string = '/data/app/el2/100/base/' + safeBg;
    const foreignPref: string = foreignBase + '/haps/entry/preferences';

    let r1: string = this.probePath('C1 本应用沙箱 preferences', ownDir);
    let r2: string = this.probePath('C2 本应用宿主 base（' + ownBundle + '）', ownHost);
    let r3: string = this.probePath('T1 他包 base（' + safeBg + '）', foreignBase);
    let r4: string = this.probePath('T2 他包 preferences', foreignPref);

    const c1Ok: boolean = r1.indexOf('可见') >= 0;
    const c2NoEnt: boolean = r2.indexOf('ENOENT') >= 0;
    const tEacces: boolean = r3.indexOf('EACCES') >= 0 || r4.indexOf('EACCES') >= 0;
    const tNoEnt: boolean = r3.indexOf('ENOENT') >= 0 || r4.indexOf('ENOENT') >= 0;

    let verdict: string = '';
    if (c1Ok && c2NoEnt) {
      verdict = '结论：应用只能看见自己的沙箱映射（/data/storage/el2/...）；'
        + '连"本应用自己的宿主路径 /data/app/el2/100/base/<自身包名>"都返回 ENOENT。'
        + '说明隔离发生在挂载命名空间层——宿主真实路径不在应用的文件视图里，'
        + '跨应用路径因此是"不可见"而非"被拒绝"，比单纯的 DAC 拒绝更强。';
      if (tEacces) {
        verdict += '\n（他包路径额外返回 EACCES：该节点在视图中存在但被安全策略拦截。）';
      }
    } else if (c1Ok && tEacces) {
      verdict = '结论：沙箱路径可见，他包路径返回 EACCES——DAC/SELinux 直接拦截，跨应用读取不成立。';
    } else if (c1Ok && tNoEnt) {
      verdict = '结论：沙箱路径可见，他包路径 ENOENT（不可见），未观察到 EACCES，属命名空间级隔离。';
    } else if (!c1Ok) {
      verdict = '结论：C1 对照组本身不可达，本机沙箱路径与预期不同，探测结论不成立，请核对 preferencesDir。';
    } else {
      verdict = '结论：C1 可见且他包路径也未报错，属异常情形，请人工复核四条 errno。';
    }
    this.sbxResult = verdict + '\n\n' + r1 + '\n\n' + r2 + '\n\n' + r3 + '\n\n' + r4;
    this.sbxMsg = '已比对 4 个路径，未读取任何文件内容';
  }

  private fontScaleOf(step: number): number {
    if (step <= 0) {
      return 0.9;
    }
    if (step >= 2) {
      return 1.16;
    }
    return 1;
  }

  private saveUiCfg(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      store.putSync('uiBg', this.bgIdx);
      store.putSync('uiAcc', this.accIdx);
      store.putSync('uiFont', this.fontStep);
      store.putSync('uiAnim', this.animOn);
      store.flush();
    } catch (e) {
    }
  }

  /** 应用外观设置：改全局色板 + 字号，然后用 themeRev 触发整页重建 */
  private applyLook(): void {
    applyThemeColors(this.bgIdx, this.accIdx);
    FS = this.fontScaleOf(this.fontStep);
    this.themeRev = this.themeRev + 1;
    this.saveUiCfg();
  }

  private switchTab(i: number): void {
    if (!this.animOn || i === this.curTab) {
      this.curTab = i;
      return;
    }
    this.getUIContext().animateTo({ duration: 110, curve: Curve.EaseOut }, () => {
      this.pageAlpha = 0;
    });
    setTimeout(() => {
      this.curTab = i;
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
        this.pageAlpha = 1;
      });
    }, 110);
  }

  /** 功能页侧栏切换子页：不整页淡出，只换内容区，避免每次点击都在等动画 */
  private switchFunc(i: number): void {
    if (this.funcSel === i) {
      return;
    }
    this.funcSel = i;
  }

  /** 侧栏 / 概览快捷入口共用：切子页 + 首次懒加载，避免一切进来就同时打三条命令 */
  private pickFunc(i: number): void {
    this.switchFunc(i);
    if (i === 1 && this.processes.length === 0) {
      this.loadProcess();
    }
    if (i === 2 && this.fileItems.length === 0) {
      this.loadDir();
    }
    if (i === 3 && this.apps.length === 0) {
      this.doAppList();
    }
  }

  /** shell 参数安全引用（与 Gateway 内同名逻辑一致，避免路径里带引号/美元符把命令拼歪） */
  private sq(s: string): string {
    return "'" + s.split("'").join("'\\''") + "'";
  }

  /** 把 TERM 输出追加到面板，整块上限 200KB，防止 cat 大文件把内存吃满 */
  private pushTerm(text: string): void {
    let next: string = this.termOut + text;
    if (next.length > 204800) {
      next = next.substring(next.length - 204800);
      next = '…（较早输出已丢弃）\n' + next;
    }
    this.termOut = next;
  }

  /**
   * 执行一条终端命令。
   * hdc 的 shell 是非交互 exec，每条命令都是新进程，所以 cd / export 不会自动保留：
   * 这里用 self.termCwd 手动维持当前目录，纯 `cd xxx` 用 `cd xxx && pwd` 反查真实路径。
   */
  private async runTerm(): Promise<void> {
    const raw: string = this.termCmd.trim();
    if (raw.length === 0 || this.termBusy) {
      return;
    }
    if (raw === 'clear' || raw === 'cls') {
      this.termOut = '';
      this.termCmd = '';
      return;
    }
    this.termBusy = true;
    this.termMsg = '执行中…';
    this.termHist = [raw].concat(this.termHist.filter((h: string) => h !== raw)).slice(0, 50);
    this.termCmd = '';
    this.pushTerm('\n$ ' + raw + '\n');

    try {
      let cmd: string = '';
      const isPureCd: boolean = /^cd\s+[^\s;&|]+$/.test(raw);
      if (isPureCd) {
        const target: string = raw.substring(2).trim();
        cmd = 'cd ' + this.sq(target) + ' && pwd';
      } else {
        cmd = 'cd ' + this.sq(this.termCwd) + ' 2>/dev/null; ' + raw;
      }
      const r: ExecResult = await Gateway.execMarked(cmd, 30000);
      const out: string = r.out.length > 0 ? r.out : '(无输出)';
      if (isPureCd && r.code === 0) {
        const lines: string[] = out.trim().split('\n');
        const p: string = lines.length > 0 ? lines[lines.length - 1].trim() : '';
        if (p.startsWith('/')) {
          this.termCwd = p;
        }
      }
      this.pushTerm(out.endsWith('\n') ? out : out + '\n');
      this.termMsg = r.code === 0 ? ('完成 · exit 0 · cwd ' + this.termCwd) : ('失败 · exit ' + r.code + ' · cwd ' + this.termCwd);
    } catch (e) {
      this.pushTerm('执行异常：' + e + '\n');
      this.termMsg = '异常';
    }
    this.termBusy = false;
  }

  private restoreApi(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      const p = store.getSync('apiPort', 18790) as number;
      if (p > 0) {
        this.apiPort = '' + p;
      }
      const wasOn = store.getSync('apiOn', false) as boolean;
      // 默认关闭：shell 是权限最大的一条端点，必须由用户显式打开
      this.shellOn = store.getSync('apiShell', false) as boolean;
      this.api.setShell(this.shellOn);
      if (wasOn) {
        this.toggleApi(true);
      }
    } catch (e) {
    }
  }

  private saveApi(on: boolean): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      store.putSync('apiOn', on);
      store.putSync('apiPort', this.num(this.apiPort, 18790));
      store.putSync('apiShell', this.shellOn);
      store.flush();
    } catch (e) {
    }
  }

  // ---------- 基础 ----------

  private loadToken(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      let t = store.getSync('token', '') as string;
      if (t.length < 12) {
        t = '';
        const chars = 'abcdef0123456789';
        for (let i = 0; i < 24; i++) {
          t += chars.charAt(Math.floor(Math.random() * chars.length));
        }
        store.putSync('token', t);
        store.flush();
      }
      this.token = t;
    } catch (e) {
      this.token = 'starpivot-default-token';
    }
  }

  private log(msg: string): void {
    const t = new Date();
    const hh = t.getHours() < 10 ? '0' + t.getHours() : '' + t.getHours();
    const mm = t.getMinutes() < 10 ? '0' + t.getMinutes() : '' + t.getMinutes();
    const ss = t.getSeconds() < 10 ? '0' + t.getSeconds() : '' + t.getSeconds();
    const line = '[' + hh + ':' + mm + ':' + ss + '] ' + msg;
    const next: string[] = [line];
    for (let i = 0; i < this.logs.length && i < 40; i++) {
      next.push(this.logs[i]);
    }
    this.logs = next;
  }

  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
    } catch (e) {
    }
  }

  private async checkBroker(): Promise<void> {
    this.log('正在检测通道 ...');
    this.channel = '检测中';
    const timer = setInterval(() => {
      if (LocalHdc.phase.length > 0) {
        this.channel = '检测中 · ' + LocalHdc.phase;
      }
    }, 1200);
    const h = await Gateway.health();
    clearInterval(timer);
    this.channel = Gateway.active === 'local' ? '本机直连' : (Gateway.active === 'pc' ? '电脑 broker' : '未连接');
    this.hdcPort = LocalHdc.port > 0 ? ('' + LocalHdc.port) : '';
    if (h === null) {
      this.brokerOk = false;
      this.sn = '未连接';
      const why: string = Gateway.lastError.length > 0
        ? Gateway.lastError
        : (LocalHdc.lastError.length > 0 ? LocalHdc.lastError : LocalHdc.phase);
      this.log('未连接：' + (why.length > 0 ? why : '电脑端 broker 离线，且本机 hdcd 不可达'));
      return;
    }
    this.brokerOk = true;
    const rawSn: string = h.sn;
    this.sn = rawSn && rawSn.length > 0 ? rawSn : '未知';
    this.hdcPath = h.hdc;
    this.log('已连接 · ' + this.channel + ' · 设备 ' + this.sn);
    const idOut = await Gateway.exec('id');
    this.ident = idOut.out.trim().length > 0 ? idOut.out.trim() : idOut.err.trim();
    const di = await Gateway.deviceInfo();
    this.devInfo = di.out.trim();
  }

  private async setMode(m: string): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await Gateway.setMode(ctx, m);
    this.connMode = m;
    this.log('连接方式切换为 ' + (m === 'pc' ? '仅电脑 broker' : (m === 'local' ? '仅本机直连' : '自动')));
    await this.checkBroker();
  }

  private num(v: string, dft: number): number {
    const n = parseInt(v);
    return isNaN(n) ? dft : n;
  }

  // ---------- 屏幕 ----------

  private async doCapture(): Promise<void> {
    this.screenMsg = '截屏中...';
    const t0: number = Date.now();
    const w: number = this.num(this.shotW, 1600);
    const h: number = this.num(this.shotH, 0);
    const b64 = await Gateway.capture(w, h);
    if (b64.length === 0) {
      this.screenMsg = '截屏失败（检查 broker 与 snapshot_display）';
      this.log(this.screenMsg);
      return;
    }
    this.shot = b64;
    this.screenMsg = '截屏成功 (' + Math.round(b64.length / 1024) + ' KB base64 · ' +
      String(Date.now() - t0) + ' ms · ' + (w <= 0 ? '原分辨率' : (String(w) + '×' + (h > 0 ? String(h) : '按比例'))) + ')';
    this.log(this.screenMsg);
  }

  /** 保存当前截图到系统相册（依赖 SaveButton 的临时授权） */
  private async saveShotToAlbum(): Promise<void> {
    if (this.shot.length === 0) {
      this.toast('先截一张图');
      return;
    }
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(ctx);
      const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'jpg');
      const bytes: Uint8Array = new util.Base64Helper().decodeSync(this.shot);
      const file = fs.openSync(uri, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      fs.writeSync(file.fd, bytes.buffer as ArrayBuffer);
      fs.closeSync(file);
      this.screenMsg = '已保存到相册（图片）';
      this.log(this.screenMsg);
      this.toast('已保存到相册');
    } catch (e) {
      const m: string = (e as Error).message;
      this.screenMsg = '保存失败：' + m;
      this.log(this.screenMsg);
      this.toast('保存失败：' + m);
    }
  }

  private async doTap(): Promise<void> {
    const r = await Gateway.tap(this.num(this.tapX, 0), this.num(this.tapY, 0));
    this.screenMsg = r.code === 0 ? ('点击 ' + this.tapX + ',' + this.tapY + ' 已注入') : ('失败: ' + r.err);
    this.log(this.screenMsg);
  }

  private async doSwipe(): Promise<void> {
    const r = await Gateway.swipe(this.num(this.swipeX1, 0), this.num(this.swipeY1, 0),
      this.num(this.swipeX2, 0), this.num(this.swipeY2, 0), 400);
    this.screenMsg = r.code === 0 ? '滑动已注入' : ('失败: ' + r.err);
    this.log(this.screenMsg);
  }

  private async doKey(k: string): Promise<void> {
    const r = await Gateway.keyEvent(k);
    this.screenMsg = r.code === 0 ? ('按键 ' + k + ' 已发送') : ('失败: ' + r.err);
    this.log(this.screenMsg);
  }

  // ---------- 进程 ----------

  private async loadProcess(): Promise<void> {
    this.procMsg = '读取进程列表...';
    const r = await Gateway.processText();
    if (r.code !== 0) {
      this.procMsg = '失败: ' + r.err;
      return;
    }
    this.processes = Gateway.parseProcess(r.out);
    this.procMsg = '共 ' + this.processes.length + ' 个进程';
    this.log(this.procMsg);
  }

  private killProc(p: ProcessItem): void {
    AlertDialog.show({
      title: '结束进程',
      message: '确定 kill -9 ' + p.name + ' (pid ' + p.pid + ') ？',
      primaryButton: {
        value: '取消', action: () => {
        }
      },
      secondaryButton: {
        value: '结束', fontColor: '#F2F2F4', action: () => {
          Gateway.killProcess(p.pid).then((r: ExecResult) => {
            this.procMsg = r.code === 0 ? ('已结束 ' + p.pid) : ('失败: ' + r.err);
            this.log(this.procMsg);
            this.loadProcess();
          });
        }
      }
    });
  }

  // ---------- 文件 ----------

  private parseLs(out: string): FileItem[] {
    const items: FileItem[] = [];
    const lines: string[] = out.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0 || line.indexOf('total ') === 0) {
        continue;
      }
      const head: string = line.charAt(0);
      if (head !== 'd' && head !== '-' && head !== 'l') {
        continue;
      }
      const seg: string[] = line.split(' ');
      const parts: string[] = [];
      for (let k = 0; k < seg.length; k++) {
        if (seg[k].length > 0) {
          parts.push(seg[k]);
        }
      }
      if (parts.length < 8) {
        continue;
      }
      let name: string = '';
      for (let k = 7; k < parts.length; k++) {
        name += (k > 7 ? ' ' : '') + parts[k];
      }
      // 软链接形如 name -> target，只取链接名
      const arrow: number = name.indexOf(' -> ');
      if (arrow >= 0) {
        name = name.substring(0, arrow);
      }
      if (name === '.' || name === '..') {
        continue;
      }
      const item: FileItem = {
        name: name,
        isDir: head !== '-',
        size: parts[4],
        mode: parts[0]
      };
      items.push(item);
    }
    return items;
  }

  private async loadDir(): Promise<void> {
    this.dirText = '读取目录 ' + this.dirPath + ' ...';
    const r = await Gateway.listDir(this.dirPath);
    if (r.code !== 0) {
      this.dirText = '失败: ' + r.err;
      this.fileItems = [];
      return;
    }
    this.dirText = '';
    this.fileItems = this.parseLs(r.out);
    this.log('列目录 ' + this.dirPath + ' · ' + this.fileItems.length + ' 项');
  }

  private goUp(): void {
    const p: string = this.dirPath;
    if (p === '/' || p.length === 0) {
      return;
    }
    const idx: number = p.lastIndexOf('/');
    this.dirPath = idx <= 0 ? '/' : p.substring(0, idx);
    this.loadDir();
  }

  private openEntry(it: FileItem): void {
    if (it.isDir) {
      this.dirPath = this.dirPath === '/' ? ('/' + it.name) : (this.dirPath + '/' + it.name);
      this.loadDir();
      return;
    }
    this.filePath = this.dirPath === '/' ? ('/' + it.name) : (this.dirPath + '/' + it.name);
    this.openTyped(it.name, it.size);
  }

  private extOf(nameOrPath: string): string {
    const slash: number = nameOrPath.lastIndexOf('/');
    const base: string = slash >= 0 ? nameOrPath.substring(slash + 1) : nameOrPath;
    const dot: number = base.lastIndexOf('.');
    return dot > 0 ? base.substring(dot + 1).toLowerCase() : '';
  }

  private isImageExt(e: string): boolean {
    const list: string[] =
      ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif', 'heic', 'heif', 'svg', 'ico'];
    return list.indexOf(e) >= 0;
  }

  private isTextExt(e: string): boolean {
    const list: string[] = ['txt', 'log', 'json', 'json5', 'xml', 'md', 'ini', 'cfg', 'conf', 'prop',
      'sh', 'js', 'ts', 'ets', 'c', 'h', 'cpp', 'java', 'kt', 'yaml', 'yml', 'csv', 'html', 'css',
      'rs', 'go', 'py', 'gradle', 'toml', 'bat', 'txt'];
    return list.indexOf(e) >= 0;
  }

  private mimeOf(e: string): string {
    if (e === 'png') {
      return 'image/png';
    }
    if (e === 'webp') {
      return 'image/webp';
    }
    if (e === 'gif') {
      return 'image/gif';
    }
    if (e === 'bmp') {
      return 'image/bmp';
    }
    if (e === 'svg') {
      return 'image/svg+xml';
    }
    return 'image/jpeg';
  }

  /** 按后缀分流：图片走预览、文本走编辑框、其它二进制不读内容 */
  private async openTyped(name: string, sizeStr: string): Promise<void> {
    const e: string = this.extOf(name);
    const size: string = this.fmtSize(sizeStr);
    if (this.isImageExt(e)) {
      this.fileKind = 'image';
      this.fileImage = '';
      this.fileMsg = '正在加载图片 · ' + size;
      this.log('预览图片 ' + this.filePath);
      const b64: string = await Gateway.pullBase64(this.filePath);
      if (b64.length === 0) {
        this.fileMsg = '图片加载失败（可能超过 broker 传输上限）';
        return;
      }
      this.fileImage = b64;
      this.fileMsg = '图片预览 · ' + e.toUpperCase() + ' · ' + size;
      return;
    }
    if (this.isTextExt(e) || e.length === 0) {
      this.fileKind = 'text';
      this.fileImage = '';
      this.readFile();
      return;
    }
    this.fileKind = 'binary';
    this.fileImage = '';
    this.fileInfo = '.' + e + ' · ' + size;
    this.fileMsg = '二进制文件（.' + e + '，' + size + '），不按文本读取，避免乱码';
    this.log(this.fileMsg);
  }

  private openPathByType(): void {
    this.openTyped(this.filePath, '0');
  }

  private async readFile(): Promise<void> {
    const r = await Gateway.readFile(this.filePath);
    if (r.code !== 0) {
      this.fileMsg = '读取失败: ' + r.err;
      return;
    }
    this.fileContent = r.out;
    this.fileMsg = '已读取 ' + r.out.length + ' 字符';
  }

  private async writeFile(): Promise<void> {
    const r = await Gateway.writeFile(this.filePath, this.fileContent);
    this.fileMsg = r.code === 0 ? '写入成功' : ('写入失败: ' + r.err);
    this.log(this.fileMsg);
    this.loadDir();
  }

  private async removeFile(): Promise<void> {
    const r = await Gateway.removeFile(this.filePath);
    this.fileMsg = r.code === 0 ? '已删除' : ('删除失败: ' + r.err);
    this.log(this.fileMsg);
    this.loadDir();
  }

  private async doSearch(): Promise<void> {
    const key: string = this.searchKey.trim();
    if (key.length === 0) {
      this.searchMsg = '先输入要搜索的文件名关键字';
      return;
    }
    const safe: string = key.split('"').join('').split("'").join('');
    this.searchMsg = '搜索中 ...';
    const r = await Gateway.exec('find "' + this.dirPath + '" -maxdepth 4 -iname "*' + safe +
      '*" 2>/dev/null | head -80', 40000);
    if (r.code !== 0) {
      this.searchMsg = '搜索失败: ' + r.err;
      this.searchHits = [];
      return;
    }
    const raw: string[] = r.out.split('\n');
    const hits: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const s: string = raw[i].trim();
      if (s.length === 0 || s.indexOf('Permission denied') >= 0 || s.indexOf('No such') >= 0) {
        continue;
      }
      if (s.charAt(0) === '/') {
        hits.push(s);
      }
    }
    this.searchHits = hits;
    this.searchMsg = hits.length === 0
      ? ('没找到含「' + key + '」的文件')
      : ('在 ' + this.dirPath + ' 下找到 ' + hits.length + ' 个（最多 80）');
    this.log(this.searchMsg);
  }

  private dirnameOf(p: string): string {
    const idx: number = p.lastIndexOf('/');
    return idx <= 0 ? '/' : p.substring(0, idx);
  }

  private openHit(path: string): void {
    this.filePath = path;
    this.dirPath = this.dirnameOf(path);
    this.openTyped(path, '0');
  }

  private fmtSize(s: string): string {
    const n: number = parseInt(s);
    if (isNaN(n)) {
      return s;
    }
    if (n < 1024) {
      return n + ' B';
    }
    if (n < 1024 * 1024) {
      return Math.round(n / 1024) + ' KB';
    }
    return (Math.round(n / 1024 / 1024 * 10) / 10) + ' MB';
  }

  // ---------- 应用 ----------

  private async doUninstall(): Promise<void> {
    if (this.bundle.length === 0) {
      this.appMsg = '请先填写包名';
      return;
    }
    const r = await Gateway.uninstall(this.bundle);
    this.appMsg = (r.out + r.err).trim();
    this.log('卸载 ' + this.bundle + ' code ' + r.code);
  }

  private async doStart(): Promise<void> {
    if (this.bundle.length === 0) {
      this.appMsg = '请先填写包名';
      return;
    }
    const r = await Gateway.startApp(this.bundle);
    this.appMsg = (r.out + r.err).trim();
    this.log('启动 ' + this.bundle + ' code ' + r.code);
  }

  private async doAppList(): Promise<void> {
    this.appMsg = '读取应用列表 ...';
    const r = await Gateway.appList();
    if (r.code !== 0) {
      this.appMsg = '失败: ' + r.err;
      return;
    }
    let parsed: boolean = false;
    try {
      const arr: AppEntry[] = JSON.parse(r.out) as AppEntry[];
      const list: AppEntry[] = [];
      for (let i = 0; i < arr.length; i++) {
        const b: string = arr[i].bundleName;
        if (b === undefined || b.length === 0) {
          continue;
        }
        let lb: string = arr[i].label;
        if (lb === undefined || lb.length === 0 || lb.indexOf('$string:') === 0) {
          lb = '';
        }
        const it: AppEntry = { bundleName: b, label: lb };
        list.push(it);
      }
      list.sort((a: AppEntry, b2: AppEntry) => a.bundleName.localeCompare(b2.bundleName));
      this.apps = list;
      parsed = true;
      this.appMsg = '共 ' + list.length + ' 个应用，点一下选中';
    } catch (e) {
      parsed = false;
    }
    if (!parsed) {
      // 老固件不支持 -l，退化成只有包名的列表
      const raw: string[] = (r.out + '\n' + r.err).split('\n');
      const list2: AppEntry[] = [];
      for (let i = 0; i < raw.length; i++) {
        const s: string = raw[i].trim();
        if (s.length === 0 || s.indexOf('error') >= 0 || s.indexOf('Exception') >= 0 ||
          s.charAt(0) === '[' || s.charAt(0) === ']' || s.charAt(0) === '{' || s.charAt(0) === '}') {
          continue;
        }
        const it2: AppEntry = { bundleName: s, label: '' };
        list2.push(it2);
      }
      this.apps = list2;
      this.appMsg = '共 ' + list2.length + ' 个应用（该固件不返回名称）';
    }
    this.appText = '';
    this.log(this.appMsg);
  }

  private appTitle(it: AppEntry): string {
    if (it.label.length > 0) {
      return it.label;
    }
    // 没有可读名称时，用包名末段做个可读名
    const seg: string[] = it.bundleName.split('.');
    const last: string = seg.length > 0 ? seg[seg.length - 1] : it.bundleName;
    return last.length > 0 ? (last.charAt(0).toUpperCase() + last.substring(1)) : it.bundleName;
  }

  private filteredApps(): AppEntry[] {
    const key: string = this.appFilter.trim().toLowerCase();
    if (key.length === 0) {
      return this.apps;
    }
    const out: AppEntry[] = [];
    for (let i = 0; i < this.apps.length; i++) {
      const a: AppEntry = this.apps[i];
      if (a.bundleName.toLowerCase().indexOf(key) >= 0 || a.label.toLowerCase().indexOf(key) >= 0) {
        out.push(a);
      }
    }
    return out;
  }

  private pickApp(b: string): void {
    this.appPicked = b;
    this.bundle = b;
    this.log('选中应用 ' + b);
  }

  // ---------- API 网关 ----------

  private async toggleApi(on: boolean): Promise<void> {
    if (on) {
      try {
        await this.api.start(this.num(this.apiPort, 18790), this.token);
        this.api.setShell(this.shellOn);
        this.apiOn = true;
        this.saveApi(true);
      } catch (e) {
        this.apiOn = false;
        this.saveApi(false);
        this.log('网关启动失败: ' + JSON.stringify(e));
        this.toast('网关启动失败，端口可能被占用');
      }
    } else {
      await this.api.stop();
      this.apiOn = false;
      this.saveApi(false);
    }
  }

  private copyToken(): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.token);
      pasteboard.getSystemPasteboard().setData(data);
      this.toast('令牌已复制');
    } catch (e) {
      this.toast('复制失败');
    }
  }

  private copySample(): void {
    const port = this.num(this.apiPort, 18790);
    const sample = 'curl -X POST http://127.0.0.1:' + port + '/v1/process/list \\\n'
      + '  -H "Content-Type: application/json" \\\n'
      + '  -H "X-StarPivot-Token: ' + this.token + '"\n'
      + '// ArkTS: http.createHttp().request(url, { method: http.RequestMethod.POST,'
      + ' header: { "X-StarPivot-Token": "' + this.token + '" } })';
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, sample);
      pasteboard.getSystemPasteboard().setData(data);
      this.toast('接入示例已复制');
    } catch (e) {
      this.toast('复制失败');
    }
  }

  private async selfTestApi(): Promise<void> {
    this.apiMsg = '正在测试网关 ...';
    const port = this.num(this.apiPort, 18790);
    try {
      const req = http.createHttp();
      const res = await req.request('http://127.0.0.1:' + port + '/v1/ping',
        { method: http.RequestMethod.GET, connectTimeout: 3000, readTimeout: 3000 });
      this.apiMsg = 'HTTP ' + res.responseCode + ' · ' + ('' + res.result);
      req.destroy();
    } catch (e) {
      this.apiMsg = '自测失败：' + JSON.stringify(e) + '（检查开关是否打开、端口是否被占用）';
    }
    this.log(this.apiMsg);
  }

  // ---------- UI ----------

  @Builder ModeChip(label: string, mode: string) {
    Text(label)
      .fontSize(fsz(13))
      .fontColor(this.connMode === mode ? ON_ACCENT : MUTED)
      .backgroundColor(this.connMode === mode ? ACCENT : CARD)
      .borderRadius(10)
      .height(38)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.setMode(mode);
      })
  }

  @Builder FontChip(label: string, step: number) {
    Text(label)
      .fontSize(fsz(13))
      .fontColor(this.fontStep === step ? ON_ACCENT : MUTED)
      .backgroundColor(this.fontStep === step ? ACCENT : CARD2)
      .borderRadius(10)
      .height(38)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        this.fontStep = step;
        this.applyLook();
      })
  }

  @Builder SectionTitle(t: string, d: string) {
    Column({ space: 2 }) {
      Text(t).fontSize(fsz(15)).fontWeight(FontWeight.Bold).fontColor(TEXT)
      Text(d).fontSize(fsz(12)).fontColor(MUTED)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder Out(text: string, color: string) {
    Text(text)
      .fontSize(fsz(11))
      .fontColor(color)
      .fontFamily('monospace')
      .width('100%')
      .padding(12)
      .backgroundColor(CARD2)
      .borderRadius(14)
  }

  @Builder Field(label: string) {
    Text(label).fontSize(fsz(12)).fontColor(MUTED).width('100%').margin({ bottom: 4 })
  }

  @Builder TabItem(index: number, title: string) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(fsz(12))
        .fontWeight(this.curTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.curTab === index ? ACCENT : MUTED)
        .maxLines(1)
      Row()
        .width(18)
        .height(2)
        .borderRadius(1)
        .backgroundColor(this.curTab === index ? ACCENT : Color.Transparent)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(index);
    })
  }

  @Builder FuncSideItem(index: number, title: string) {
    Row({ space: 6 }) {
      Row()
        .width(3)
        .height(16)
        .borderRadius(2)
        .backgroundColor(this.funcSel === index ? ACCENT : Color.Transparent)
      Text(title)
        .fontSize(fsz(12))
        .fontWeight(this.funcSel === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.funcSel === index ? TEXT : MUTED)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .height(this.sideW < 110 ? 40 : 44)
    .padding({ left: 8, right: 8 })
    .borderRadius(10)
    .backgroundColor(this.funcSel === index ? ACCENT_SOFT : Color.Transparent)
    .onClick(() => {
      this.pickFunc(index);
    })
  }

  /** 功能页：左窄侧栏 + 右内容区，替代原来的 6 个独立底栏页签 */
  @Builder FuncTab() {
    Row() {
      Column() {
        Text('功能')
          .fontSize(fsz(10))
          .fontColor(MUTED)
          .width('100%')
          .padding({ left: 8, top: 10, bottom: 6 })

        // 字号放大后 6 项会超出可视高度，侧栏自己能滚
        Scroll() {
          Column({ space: 4 }) {
            this.FuncSideItem(0, '屏幕')
            this.FuncSideItem(1, '进程')
            this.FuncSideItem(2, '文件')
            this.FuncSideItem(3, '应用')
            this.FuncSideItem(4, '解锁')
            this.FuncSideItem(5, '诊断')
            this.FuncSideItem(6, '终端')
          }
          .width('100%')
          .padding({ bottom: 12 })
          .alignItems(HorizontalAlign.Start)
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
      }
      .width(this.sideW)
      .height('100%')
      .padding({ left: 4, right: 4 })
      .backgroundColor(BG_DEEP)
      .borderRadius({ topRight: 14, bottomRight: 14 })
      .alignItems(HorizontalAlign.Start)

      Column() {
        if (this.funcSel === 0) {
          this.ScreenTab()
        } else if (this.funcSel === 1) {
          this.ProcessTab()
        } else if (this.funcSel === 2) {
          this.FileTab()
        } else if (this.funcSel === 3) {
          this.AppTab()
        } else if (this.funcSel === 4) {
          this.UnlockTab()
        } else if (this.funcSel === 5) {
          this.DiagTab()
        } else {
          this.TermTab()
        }
      }
      .layoutWeight(1)
      .height('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(VerticalAlign.Top)
  }

  @Builder Header() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('StarPivot').fontSize(fsz(18)).fontWeight(FontWeight.Bold).fontColor(ACCENT)
        Text('星枢 · HDC 能力网关 · r4').fontSize(fsz(12)).fontColor(MUTED)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(4)
          .backgroundColor(this.brokerOk ? OKC : WARN)
        Text(this.brokerOk ? ('已连接 ' + this.sn) : '未连接')
          .fontSize(fsz(11))
          .fontColor(this.brokerOk ? ACCENT : MUTED)
          .maxLines(1)
      }
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(CARD)
      .borderRadius(20)
      .onClick(() => {
        this.checkBroker();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  @Builder CapCell(t: string, s: string) {
    Column({ space: 2 }) {
      Text(t).fontSize(fsz(14)).fontWeight(FontWeight.Bold).fontColor(ACCENT)
      Text(s).fontSize(fsz(11)).fontColor(MUTED)
    }
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .layoutWeight(1)
    .backgroundColor(CARD2)
    .borderRadius(14)
  }

  @Builder QuickCell(title: string, sub: string, idx: number) {
    Column({ space: 4 }) {
      Text(title).fontSize(fsz(15)).fontWeight(FontWeight.Bold).fontColor(TEXT)
      Text(sub).fontSize(fsz(10)).fontColor(MUTED).maxLines(1)
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .layoutWeight(1)
    .backgroundColor(CARD2)
    .borderRadius(14)
    .onClick(() => {
      this.pickFunc(idx);
      this.switchTab(1);
    })
  }

  @Builder OverviewTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.SectionTitle('连接状态', '电脑 broker 或 本机 hdcd 直连 → hdc shell')

        Column({ space: 8 }) {
          Row() {
            Text('当前通道').fontSize(fsz(12)).fontColor(MUTED)
            Blank()
            Text(this.channel).fontSize(fsz(12)).fontColor(this.brokerOk ? OKC : WARN)
          }
          .width('100%')

          Row() {
            Text('设备序列号').fontSize(fsz(12)).fontColor(MUTED)
            Blank()
            Text(this.sn).fontSize(fsz(12)).fontColor(TEXT)
          }
          .width('100%')

          if (this.hdcPort.length > 0) {
            Row() {
              Text('hdcd 端口').fontSize(fsz(12)).fontColor(MUTED)
              Blank()
              Text('127.0.0.1:' + this.hdcPort).fontSize(fsz(12)).fontColor(TEXT)
            }
            .width('100%')
          }

          Row() {
            Text('执行身份').fontSize(fsz(12)).fontColor(MUTED)
            Blank()
            Text(this.ident.length > 0 ? this.ident : '-')
              .fontSize(fsz(11)).fontColor(TEXT).maxLines(2).textAlign(TextAlign.End).layoutWeight(1)
          }
          .width('100%')
        }
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        Button(this.brokerOk ? '启动（已连接，点此重连）' : '启动')
          .width('100%').height(48).fontSize(fsz(15)).fontWeight(FontWeight.Bold)
          .backgroundColor(ACCENT).fontColor(ON_ACCENT).borderRadius(14)
          .stateEffect(this.animOn)
          .onClick(() => {
            this.checkBroker();
          })

        Row({ space: 8 }) {
          Button('设备信息').width('100%').height(50).fontSize(fsz(15))
            .backgroundColor(Color.Transparent).fontColor(ACCENT).borderRadius(12)
            .border({ width: 1.5, color: ACCENT })
            .onClick(async () => {
              const di = await Gateway.deviceInfo();
              this.devInfo = di.out.trim();
              this.log('读取设备信息');
            })
        }

        if (this.devInfo.length > 0) {
          this.Out(this.devInfo, TEXT)
        }

        this.SectionTitle('快捷功能', '点击直达，六个页签已合并到「功能」')
        Row({ space: 8 }) {
          this.QuickCell('屏幕', '截图 / 点击 / 输入', 0)
          this.QuickCell('进程', '列表 / 详情 / 强停', 1)
          this.QuickCell('文件', '浏览 / 读写 / 删除', 2)
        }
        .width('100%')
        Row({ space: 8 }) {
          this.QuickCell('应用', '列表 / 启动 / 安装', 3)
          this.QuickCell('解锁', '亮屏 / 上滑 / PIN', 4)
          this.QuickCell('诊断', 'DFX / 探测 / 自查', 5)
        }
        .width('100%')

        this.SectionTitle('运行日志', '最近 20 条')
        Column({ space: 6 }) {
          if (this.logs.length === 0) {
            Text('暂无日志').fontSize(fsz(11)).fontColor(MUTED)
          }
          ForEach(this.logs.slice(0, 20), (line: string) => {
            Text(line).fontSize(fsz(10)).fontColor(MUTED).fontFamily('monospace').width('100%')
          }, (line: string, idx: number) => idx.toString() + line)
        }
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(18)
        .width('100%')
        .margin({ bottom: 24 })
      }
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }

  @Builder ScreenTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.SectionTitle('屏幕截取', 'snapshot_display → 实时回传到本页')
        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text('宽度 px').fontSize(fsz(11)).fontColor(MUTED).width('100%')
            TextInput({ text: $$this.shotW, placeholder: '0 = 原分辨率' }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)

          Column({ space: 4 }) {
            Text('高度 px').fontSize(fsz(11)).fontColor(MUTED).width('100%')
            TextInput({ text: $$this.shotH, placeholder: '0 = 按比例' }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)

          Button('1080').height(38).fontSize(fsz(12)).margin({ top: 18 })
            .backgroundColor(CARD).fontColor(ACCENT).borderRadius(10)
            .onClick(() => {
              this.shotW = '1080';
              this.shotH = '0';
            })
          Button('2800').height(38).fontSize(fsz(12)).margin({ top: 18 })
            .backgroundColor(CARD).fontColor(ACCENT).borderRadius(10)
            .onClick(() => {
              this.shotW = '2800';
              this.shotH = '1840';
            })
        }
        .width('100%')

        Button(this.shot.length > 0 ? '重新截屏' : '截取当前屏幕')
          .width('100%').height(44).fontSize(fsz(14))
          .backgroundColor(ACCENT).fontColor(ON_ACCENT)
          .stateEffect(this.animOn)
          .onClick(() => {
            this.doCapture();
          })

        if (this.shot.length > 0) {
          SaveButton({
            icon: SaveIconStyle.FULL_FILLED,
            text: SaveDescription.SAVE_IMAGE,
            buttonType: ButtonType.Capsule
          })
            .width('100%').height(44).fontSize(fsz(14))
            .backgroundColor(CARD).fontColor(ACCENT)
            .onClick(async (event: ClickEvent, result: SaveButtonOnClickResult) => {
              if (result === SaveButtonOnClickResult.SUCCESS) {
                await this.saveShotToAlbum();
              } else {
                this.toast('未获得保存授权');
              }
            })
        }

        if (this.shot.length > 0) {
          Image('data:image/jpeg;base64,' + this.shot)
            .width('100%')
            .height(320)
            .objectFit(ImageFit.Contain)
            .borderRadius(12)
            .backgroundColor(CARD)
            .transition(TransitionEffect.OPACITY.animation({ duration: this.animOn ? 220 : 1 }))
        }

        if (this.screenMsg.length > 0) {
          this.Out(this.screenMsg, MUTED)
        }

        this.SectionTitle('点击注入', 'uitest uiInput click x y')
        Row({ space: 8 }) {
          Column() {
            this.Field('X')
            TextInput({ text: $$this.tapX }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)

          Column() {
            this.Field('Y')
            TextInput({ text: $$this.tapY }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)

          Button('注入').width(76).height(38).fontSize(fsz(13)).margin({ top: 15 })
            .backgroundColor(CARD).fontColor(ACCENT)
            .onClick(() => {
              this.doTap();
            })
        }

        this.SectionTitle('滑动注入', 'uitest uiInput swipe')
        Row({ space: 8 }) {
          Column() {
            this.Field('起 X')
            TextInput({ text: $$this.swipeX1 }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)
          Column() {
            this.Field('起 Y')
            TextInput({ text: $$this.swipeY1 }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)
        }
        Row({ space: 8 }) {
          Column() {
            this.Field('终 X')
            TextInput({ text: $$this.swipeX2 }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)
          Column() {
            this.Field('终 Y')
            TextInput({ text: $$this.swipeY2 }).type(InputType.Number).height(38).fontSize(fsz(13))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          }.layoutWeight(1)
        }
        Button('执行滑动').width('100%').height(40).fontSize(fsz(13))
          .backgroundColor(CARD).fontColor(TEXT)
          .onClick(() => {
            this.doSwipe();
          })

        this.SectionTitle('按键', 'uitest uiInput keyEvent')
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).height(38).fontSize(fsz(13)).backgroundColor(CARD).fontColor(TEXT)
            .onClick(() => {
              this.doKey('Back');
            })
          Button('桌面').layoutWeight(1).height(38).fontSize(fsz(13)).backgroundColor(CARD).fontColor(TEXT)
            .onClick(() => {
              this.doKey('Home');
            })
          Button('电源').layoutWeight(1).height(38).fontSize(fsz(13)).backgroundColor(CARD).fontColor(TEXT)
            .onClick(() => {
              this.doKey('Power');
            })
        }
        .margin({ bottom: 24 })
      }
      .padding(16)
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }

  @Builder ProcessTab() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('进程列表').fontSize(fsz(15)).fontWeight(FontWeight.Medium).fontColor(TEXT)
          Text('ps -ef').fontSize(fsz(11)).fontColor(MUTED)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('刷新').height(32).fontSize(fsz(12)).backgroundColor(CARD).fontColor(ACCENT)
          .onClick(() => {
            this.loadProcess();
          })
      }
      .width('100%')

      if (this.procMsg.length > 0) {
        Text(this.procMsg).fontSize(fsz(11)).fontColor(MUTED).width('100%')
      }

      List({ space: 6 }) {
        ForEach(this.processes, (p: ProcessItem) => {
          ListItem() {
            Row({ space: 10 }) {
              Text('' + p.pid).fontSize(fsz(11)).fontColor(ACCENT).width(56).fontFamily('monospace')
              Text(p.name).fontSize(fsz(12)).fontColor(TEXT).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(p.uid).fontSize(fsz(10)).fontColor(MUTED).maxLines(1)
              Text('结束').fontSize(fsz(11)).fontColor(DEL_TX)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(DEL_BG)
                .borderRadius(12)
                .onClick(() => {
                  this.killProc(p);
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor(CARD2)
            .borderRadius(14)
          }
        }, (p: ProcessItem, idx: number) => p.pid + '_' + idx)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .padding(16)
    .width('100%')
    .height('100%')
  }

  @Builder FileRow(it: FileItem) {
    Row({ space: 10 }) {
      Text(it.isDir ? 'DIR' : 'FILE')
        .fontSize(fsz(10)).fontWeight(FontWeight.Bold)
        .fontColor(it.isDir ? ON_ACCENT : ACCENT)
        .backgroundColor(it.isDir ? ACCENT : ACCENT_SOFT)
        .borderRadius(6)
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .width(40)
        .textAlign(TextAlign.Center)

      Column({ space: 2 }) {
        Text(it.name)
          .fontSize(fsz(13)).fontColor(TEXT).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(it.isDir ? '目录' : (this.fmtSize(it.size) + ' · ' + it.mode))
          .fontSize(fsz(10)).fontColor(MUTED).maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!it.isDir) {
        Text('打开 ›').fontSize(fsz(11)).fontColor(ACCENT)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(CARD2)
    .borderRadius(14)
    .onClick(() => {
      this.openEntry(it);
    })
  }

  @Builder HitRow(path: string) {
    Row({ space: 10 }) {
      Text('FILE').fontSize(fsz(10)).fontWeight(FontWeight.Bold)
        .fontColor(ACCENT).backgroundColor(ACCENT_SOFT)
        .borderRadius(6).padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .width(40).textAlign(TextAlign.Center)
      Text(path).fontSize(fsz(12)).fontColor(TEXT)
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('打开 ›').fontSize(fsz(11)).fontColor(ACCENT)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(CARD2)
    .borderRadius(14)
    .onClick(() => {
      this.openHit(path);
    })
  }

  @Builder FileTab() {
    Column() {
      // 常驻顶部：文件读写
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('文件读写').fontSize(fsz(15)).fontWeight(FontWeight.Bold).fontColor(TEXT)
          Text('按后缀识别').fontSize(fsz(10)).fontColor(MUTED)
          Blank()
          Text(this.fileKind === 'image' ? '图片' : (this.fileKind === 'binary' ? '二进制' : '文本'))
            .fontSize(fsz(10)).fontColor(ACCENT)
        }
        .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: $$this.filePath, placeholder: '/data/local/tmp/xxx.txt' })
            .height(36).fontSize(fsz(12)).layoutWeight(1)
            .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          Button('打开').width(58).height(36).fontSize(fsz(12))
            .backgroundColor(CARD2).fontColor(ACCENT).borderRadius(12)
            .onClick(() => {
              this.openPathByType();
            })
        }
        Row({ space: 8 }) {
          Button('读取').layoutWeight(1).height(36).fontSize(fsz(12)).backgroundColor(CARD2).fontColor(TEXT)
            .borderRadius(12)
            .onClick(() => {
              this.openPathByType();
            })
          Button('写入').layoutWeight(1).height(36).fontSize(fsz(12)).backgroundColor(CARD2).fontColor(TEXT)
            .borderRadius(12)
            .onClick(() => {
              this.writeFile();
            })
          Button('删除').layoutWeight(1).height(36).fontSize(fsz(12)).backgroundColor(DEL_BG).fontColor(DEL_TX)
            .borderRadius(12)
            .onClick(() => {
              this.removeFile();
            })
        }

        if (this.fileKind === 'image' && this.fileImage.length > 0) {
          Image('data:' + this.mimeOf(this.extOf(this.filePath)) + ';base64,' + this.fileImage)
            .width('100%')
            .height(170)
            .objectFit(ImageFit.Contain)
            .backgroundColor(CARD2)
            .borderRadius(14)
        } else if (this.fileKind === 'binary') {
          Column({ space: 4 }) {
            Text('二进制文件，未读取内容 · ' + this.fileInfo).fontSize(fsz(12)).fontColor(TEXT)
            Text('cat 读出来是乱码，所以只显示信息；要原始内容走 /v1/file/read 或电脑端 pull。')
              .fontSize(fsz(10)).fontColor(MUTED)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(10)
          .backgroundColor(CARD2)
          .borderRadius(12)
        } else {
          TextArea({ text: $$this.fileContent })
            .height(130).fontSize(fsz(12)).width('100%')
            .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
            .placeholderColor(MUTED)
        }

        if (this.fileMsg.length > 0) {
          Text(this.fileMsg).fontSize(fsz(10)).fontColor(MUTED).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor(BG_DEEP)
      .border({ width: { bottom: 1 }, color: LINE })

      // 可滚动部分
      Scroll() {
        Column({ space: 12 }) {
          this.SectionTitle('文件搜索', 'find -iname，在当前目录下递归 4 层')
          Row({ space: 8 }) {
            TextInput({ text: $$this.searchKey, placeholder: '文件名关键字，如 jpeg / log / report' })
              .height(36).fontSize(fsz(12)).layoutWeight(1)
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
            Button('搜索').width(60).height(36).fontSize(fsz(12))
              .backgroundColor(ACCENT).fontColor(ON_ACCENT).borderRadius(12)
              .onClick(() => {
                this.doSearch();
              })
          }
          if (this.searchMsg.length > 0) {
            Text(this.searchMsg).fontSize(fsz(11)).fontColor(MUTED).width('100%')
          }
          if (this.searchHits.length > 0) {
            Column({ space: 6 }) {
              ForEach(this.searchHits, (p: string) => {
                this.HitRow(p)
              }, (p: string, idx: number) => p + '_' + idx)
            }
            .width('100%')
            .padding(10)
            .backgroundColor(CARD)
            .borderRadius(18)
          }

          this.SectionTitle('文件浏览器', '点目录进去，点文件直接打开')
          Row({ space: 8 }) {
            Button('↑ 上级').width(72).height(36).fontSize(fsz(12))
              .backgroundColor(CARD2).fontColor(ACCENT).borderRadius(12)
              .onClick(() => {
                this.goUp();
              })
            TextInput({ text: $$this.dirPath })
              .height(36).fontSize(fsz(12)).layoutWeight(1)
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
            Button('刷新').width(60).height(36).fontSize(fsz(12))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
              .onClick(() => {
                this.loadDir();
              })
          }

          if (this.dirText.length > 0) {
            Text(this.dirText).fontSize(fsz(11)).fontColor(MUTED).width('100%')
          }

          Column({ space: 6 }) {
            if (this.fileItems.length === 0) {
              Text('点「刷新」读取当前目录').fontSize(fsz(11)).fontColor(MUTED).width('100%')
            }
            ForEach(this.fileItems, (it: FileItem) => {
              this.FileRow(it)
            }, (it: FileItem, idx: number) => it.name + '_' + idx)
          }
          .width('100%')
          .padding(10)
          .backgroundColor(CARD)
          .borderRadius(18)
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder AppRow(it: AppEntry) {
    Row({ space: 10 }) {
      Text(this.appTitle(it).substring(0, 1))
        .fontSize(fsz(15)).fontWeight(FontWeight.Bold)
        .fontColor(this.appPicked === it.bundleName ? ON_ACCENT : ACCENT)
        .width(36).height(36).borderRadius(12)
        .backgroundColor(this.appPicked === it.bundleName ? ACCENT : ACCENT_SOFT)
        .textAlign(TextAlign.Center)

      Column({ space: 2 }) {
        Text(this.appTitle(it))
          .fontSize(fsz(14)).fontWeight(FontWeight.Medium)
          .fontColor(this.appPicked === it.bundleName ? ACCENT : TEXT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(it.bundleName)
          .fontSize(fsz(10)).fontColor(MUTED).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.appPicked === it.bundleName) {
        Text('✓').fontSize(fsz(14)).fontColor(ACCENT)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: 12, top: 8, bottom: 8 })
    .backgroundColor(this.appPicked === it.bundleName ? CARD : CARD2)
    .borderRadius(14)
    .onClick(() => {
      this.pickApp(it.bundleName);
    })
  }

  @Builder AppTab() {
    Column() {
      // 常驻顶部：操作
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('应用操作').fontSize(fsz(15)).fontWeight(FontWeight.Bold).fontColor(TEXT)
          Text('bm uninstall · aa start').fontSize(fsz(10)).fontColor(MUTED)
          Blank()
          if (this.bundle.length > 0) {
            Text('已选').fontSize(fsz(10)).fontColor(ACCENT)
          }
        }
        .width('100%')

        TextInput({ text: $$this.bundle, placeholder: 'com.example.app（可手填或点下面列表）' })
          .height(36).fontSize(fsz(12)).width('100%')
          .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
        Row({ space: 8 }) {
          Button('卸载').layoutWeight(1).height(40).fontSize(fsz(13)).backgroundColor(DEL_BG).fontColor(DEL_TX)
            .borderRadius(12)
            .onClick(() => {
              this.doUninstall();
            })
          Button('启动').layoutWeight(1).height(40).fontSize(fsz(13)).fontWeight(FontWeight.Bold)
            .backgroundColor(ACCENT).fontColor(ON_ACCENT).borderRadius(12)
            .onClick(() => {
              this.doStart();
            })
        }

        if (this.appMsg.length > 0) {
          Text(this.appMsg).fontSize(fsz(10)).fontColor(MUTED).width('100%').maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor(BG_DEEP)
      .border({ width: { bottom: 1 }, color: LINE })

      // 可滚动部分
      Scroll() {
        Column({ space: 12 }) {
          this.SectionTitle('应用列表', '点一下选中，自动填到上面的包名框')
          Row({ space: 8 }) {
            TextInput({ text: $$this.appFilter, placeholder: '搜索应用名 / 包名' })
              .height(36).fontSize(fsz(12)).layoutWeight(1)
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
            Button('刷新').width(60).height(36).fontSize(fsz(12))
              .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
              .onClick(() => {
                this.doAppList();
              })
          }

          if (this.apps.length === 0) {
            Text('还没有列表，点「刷新」读取设备上已安装的应用').fontSize(fsz(12)).fontColor(MUTED).width('100%')
          } else {
            Text('共 ' + this.filteredApps().length + ' 个').fontSize(fsz(11)).fontColor(MUTED).width('100%')
          }

          if (this.appText.length > 0) {
            this.Out(this.appText, MUTED)
          }

          Column({ space: 6 }) {
            ForEach(this.filteredApps(), (it: AppEntry) => {
              this.AppRow(it)
            }, (it: AppEntry, idx: number) => it.bundleName + '_' + idx)
          }
          .width('100%')
          .padding(10)
          .backgroundColor(CARD)
          .borderRadius(18)
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }

  @Builder UnlockTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.SectionTitle('一键解锁', '亮屏 → 从屏幕中部上滑 → 按 PIN 键盘坐标点按，整条序列一次执行，避免中途熄屏')

        Column({ space: 10 }) {
          Text('锁屏 PIN').fontSize(fsz(12)).fontColor(MUTED).alignSelf(ItemAlign.Start)
          TextInput({ text: this.pinText, placeholder: '数字密码，仅保存在本机' })
            .type(InputType.Number)
            .maxLength(8)
            .height(46)
            .backgroundColor(CARD2)
            .fontColor(TEXT)
            .fontSize(fsz(16))
            .borderRadius(12)
            .onChange((v: string) => {
              this.pinText = v;
            })

          Row({ space: 10 }) {
            Column({ space: 4 }) {
              Text('亮屏后延时 ms').fontSize(fsz(11)).fontColor(MUTED)
              TextInput({ text: this.unlockDelay })
                .type(InputType.Number)
                .height(42)
                .backgroundColor(CARD2)
                .fontColor(TEXT)
                .fontSize(fsz(14))
                .borderRadius(10)
                .onChange((v: string) => {
                  this.unlockDelay = v;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 4 }) {
              Text('按键间隔 ms').fontSize(fsz(11)).fontColor(MUTED)
              TextInput({ text: this.unlockGap })
                .type(InputType.Number)
                .height(42)
                .backgroundColor(CARD2)
                .fontColor(TEXT)
                .fontSize(fsz(14))
                .borderRadius(10)
                .onChange((v: string) => {
                  this.unlockGap = v;
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('先熄屏再解锁').fontSize(fsz(13)).fontColor(TEXT)
              Text('测试用：先用 Power 把屏按灭，1.2 秒后再走完整解锁序列')
                .fontSize(fsz(10)).fontColor(MUTED)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.offFirst })
              .selectedColor(ACCENT)
              .onChange((v: boolean) => {
                this.offFirst = v;
                this.saveUnlock();
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Button('一键解锁')
              .layoutWeight(1)
              .height(46)
              .backgroundColor(ACCENT)
              .fontColor(ON_ACCENT)
              .fontSize(fsz(15))
              .onClick(() => {
                this.doUnlock();
              })
            Button('仅亮屏')
              .width(110)
              .height(46)
              .backgroundColor(CARD2)
              .fontColor(TEXT)
              .fontSize(fsz(15))
              .onClick(() => {
                this.doWake();
              })
          }
          .width('100%')

          if (this.unlockMsg.length > 0) {
            Text(this.unlockMsg).fontSize(fsz(12)).fontColor(ACCENT)
              .alignSelf(ItemAlign.Start)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(14)

        this.SectionTitle('说明', '坐标实测自 2800×1840 锁屏键盘，其它分辨率会按比例换算')
        Column({ space: 6 }) {
          Text('· 键盘三列 x ≈ 0.394 / 0.5 / 0.605，三行 y ≈ 0.421 / 0.566 / 0.712，0 键 y ≈ 0.857')
            .fontSize(fsz(11)).fontColor(MUTED).alignSelf(ItemAlign.Start)
          Text('· 亮屏用 power-shell wakeup（非切换），比 Power 键稳，不会把已亮的屏按灭')
            .fontSize(fsz(11)).fontColor(MUTED).alignSelf(ItemAlign.Start)
          Text('· 上滑起点在屏幕中部，终点向上 0.3 屏高，速度 12000')
            .fontSize(fsz(11)).fontColor(MUTED).alignSelf(ItemAlign.Start)
          Text('· 若某一环失败，把「亮屏后延时」加到 1200ms 再试')
            .fontSize(fsz(11)).fontColor(MUTED).alignSelf(ItemAlign.Start)
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(14)

        Row().height(24)
      }
      .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }

  @Builder DiagTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.SectionTitle('系统诊断', '全部走 hidumper 全局选项，uid 2000 可直接读')

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Button('内存全表').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('mem'); })
            Button('CPU 负载').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('cpu'); })
            Button('崩溃记录').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('crash'); })
          }
          .width('100%')
          Row({ space: 8 }) {
            Button('网卡信息').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('iface'); })
            Button('网络流量').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('traffic'); })
          }
          .width('100%')
          Row({ space: 8 }) {
            Button('CPU 频率').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('cpufreq'); })
            Button('系统信息').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('cluster'); })
            Button('共享库').layoutWeight(1).height(42).backgroundColor(CARD2).fontColor(TEXT)
              .fontSize(fsz(13)).onClick(() => { this.runDiag('shared'); })
          }
          .width('100%')

          Row({ space: 8 }) {
            TextInput({ text: this.urlText, placeholder: 'https://...' })
              .layoutWeight(1)
              .height(42)
              .backgroundColor(CARD2)
              .fontColor(TEXT)
              .fontSize(fsz(12))
              .borderRadius(10)
              .onChange((v: string) => {
                this.urlText = v;
              })
            Button('HTTPS 探测')
              .width(120)
              .height(42)
              .backgroundColor(ACCENT)
              .fontColor(ON_ACCENT)
              .fontSize(fsz(13))
              .onClick(() => { this.runDiag('http'); })
          }
          .width('100%')

          Row({ space: 8 }) {
            TextInput({ text: this.crashId, placeholder: '崩溃 record_id' })
              .layoutWeight(1)
              .height(42)
              .backgroundColor(CARD2)
              .fontColor(TEXT)
              .fontSize(fsz(13))
              .borderRadius(10)
              .onChange((v: string) => {
                this.crashId = v;
              })
            Button('看崩溃详情')
              .width(120)
              .height(42)
              .backgroundColor(ACCENT)
              .fontColor(ON_ACCENT)
              .fontSize(fsz(13))
              .onClick(() => { this.runDiag('detail'); })
          }
          .width('100%')

          if (this.diagMsg.length > 0) {
            Text(this.diagMsg).fontSize(fsz(12)).fontColor(ACCENT).alignSelf(ItemAlign.Start)
          }
          if (this.diagText.length > 0) {
            Text(this.diagText)
              .fontSize(fsz(10))
              .fontColor(MUTED)
              .width('100%')
              .padding(10)
              .backgroundColor(BG_DEEP)
              .borderRadius(10)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(14)

        // F-01 双路径对照自查（本机取证用，不影响任何网络接口）
        Column({ space: 10 }) {
          Text('F-01 双路径对照自查')
            .fontSize(fsz(13))
            .fontColor(TEXT)
            .fontWeight(FontWeight.Medium)
            .alignSelf(ItemAlign.Start)
          Text('比对"直接访问崩溃日志目录"与"经服务代理读取"两条路径的策略一致性。结果只在本屏显示，不上传、不落盘、不进 API 列表。')
            .fontSize(fsz(10))
            .fontColor(MUTED)
            .width('100%')

          Button('运行对照自查')
            .width('100%')
            .height(42)
            .backgroundColor(CARD2)
            .fontColor(TEXT)
            .fontSize(fsz(13))
            .onClick(() => { this.runF01(); })

          if (this.f01Verdict.length > 0) {
            Text(this.f01Verdict)
              .fontSize(fsz(12))
              .fontColor(WARN)
              .width('100%')
              .padding(10)
              .backgroundColor(BG_DEEP)
              .borderRadius(10)
          }
          if (this.f01Msg.length > 0) {
            Text(this.f01Msg).fontSize(fsz(10)).fontColor(MUTED).width('100%')
          }

          Divider().color(CARD2).margin({ top: 4, bottom: 4 })

          Text('单条记录读取（需先确认）')
            .fontSize(fsz(12))
            .fontColor(TEXT)
            .alignSelf(ItemAlign.Start)
          Row({ space: 8 }) {
            Toggle({ type: ToggleType.Switch, isOn: this.f01Armed })
              .selectedColor(ACCENT)
              .onChange((on: boolean) => {
                this.f01Armed = on;
              })
            Text('我确认仅在本机取证使用')
              .fontSize(fsz(11))
              .fontColor(MUTED)
              .layoutWeight(1)
          }
          .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.f01Id, placeholder: 'record_id（从列表复制）' })
              .layoutWeight(1)
              .height(42)
              .backgroundColor(CARD2)
              .fontColor(TEXT)
              .fontSize(fsz(12))
              .borderRadius(10)
              .onChange((v: string) => {
                this.f01Id = v;
              })
            Button('读取')
              .width(80)
              .height(42)
              .backgroundColor(this.f01Armed ? WARN : CARD2)
              .fontColor(this.f01Armed ? Color.White : MUTED)
              .fontSize(fsz(13))
              .enabled(this.f01Armed)
              .onClick(() => { this.runF01Read(); })
          }
          .width('100%')

          if (this.f01Text.length > 0) {
            Text(this.f01Text)
              .fontSize(fsz(9))
              .fontColor(MUTED)
              .width('100%')
              .padding(10)
              .backgroundColor(BG_DEEP)
              .borderRadius(10)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(14)

        // 沙箱隔离探测（只读、只比 errno）
        Column({ space: 10 }) {
          Text('沙箱隔离探测')
            .fontSize(fsz(13))
            .fontColor(TEXT)
            .fontWeight(FontWeight.Medium)
            .alignSelf(ItemAlign.Start)
          Text('对照组＝本应用 preferences 目录；实验组＝另一个包的同一类路径。只做存在性检查，不打开、不读取、不导出任何文件内容。')
            .fontSize(fsz(10))
            .fontColor(MUTED)
            .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.sbxBundle, placeholder: '目标包名，如 com.huawei.hmos.settings' })
              .layoutWeight(1)
              .height(42)
              .backgroundColor(CARD2)
              .fontColor(TEXT)
              .fontSize(fsz(12))
              .borderRadius(10)
              .onChange((v: string) => {
                this.sbxBundle = v;
              })
            Button('运行探测')
              .width(96)
              .height(42)
              .backgroundColor(CARD2)
              .fontColor(TEXT)
              .fontSize(fsz(13))
              .onClick(() => { this.runSbx(); })
          }
          .width('100%')

          if (this.sbxMsg.length > 0) {
            Text(this.sbxMsg).fontSize(fsz(10)).fontColor(MUTED).width('100%')
          }
          if (this.sbxResult.length > 0) {
            Text(this.sbxResult)
              .fontSize(fsz(9))
              .fontColor(MUTED)
              .width('100%')
              .padding(10)
              .backgroundColor(BG_DEEP)
              .borderRadius(10)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(14)

        // DFX 调试工具横向排查（只读）
        Column({ space: 10 }) {
          Text('DFX 横向排查（只读）')
            .fontSize(fsz(13))
            .fontColor(TEXT)
            .fontWeight(FontWeight.Medium)
            .alignSelf(ItemAlign.Start)
          Text('对 hidumper / bm / hisysevent / hilog 的常用只读子命令逐条试跑，只记录"被拒 / 空正文 / 有数据"，不保存任何输出内容。')
            .fontSize(fsz(10))
            .fontColor(MUTED)
            .width('100%')
          Button(this.dfxRunning ? '排查中…' : '运行横向排查')
            .width('100%')
            .height(44)
            .backgroundColor(this.dfxRunning ? CARD2 : ACCENT)
            .fontColor(this.dfxRunning ? MUTED : '#1F1F22')
            .fontSize(fsz(13))
            .enabled(!this.dfxRunning)
            .onClick(() => { this.runDfx(); })
          if (this.dfxMsg.length > 0) {
            Text(this.dfxMsg).fontSize(fsz(10)).fontColor(MUTED).width('100%')
          }
          if (this.dfxText.length > 0) {
            Text(this.dfxText)
              .fontSize(fsz(9))
              .fontColor(MUTED)
              .width('100%')
              .padding(10)
              .backgroundColor(BG_DEEP)
              .borderRadius(10)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(CARD)
        .borderRadius(14)

        Row().height(24)
      }
      .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }

  @Builder ApiRow(m: string, p: string, d: string) {
    Column({ space: 2 }) {
      Row({ space: 8 }) {
        Text(m).fontSize(fsz(9)).fontColor(m === 'GET' ? OKC : WARN).width(30)
        Text(p).fontSize(fsz(11)).fontColor(TEXT).fontFamily('monospace').layoutWeight(1)
      }
      .width('100%')
      Text(d).fontSize(fsz(9)).fontColor(MUTED).width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder TermTab() {
    Column({ space: 10 }) {
      this.SectionTitle('终端', 'uid=2000(shell) · 非交互 exec，cd 由本页自行维持')

      Row({ space: 8 }) {
        Text('cwd').fontSize(fsz(10)).fontColor(MUTED)
        Text(this.termCwd)
          .fontSize(fsz(11)).fontColor(ACCENT).fontFamily('monospace')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      Row({ space: 8 }) {
        TextInput({ text: $$this.termCmd, placeholder: '例如: ls -l /data/local/tmp' })
          .height(42).fontSize(fsz(13)).fontFamily('monospace')
          .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
          .layoutWeight(1)
          .onSubmit(() => {
            this.runTerm();
          })
        Button(this.termBusy ? '…' : '执行')
          .height(42).width(64).fontSize(fsz(13))
          .backgroundColor(this.termBusy ? CARD2 : ACCENT)
          .fontColor(this.termBusy ? MUTED : ON_ACCENT)
          .borderRadius(12)
          .enabled(!this.termBusy)
          .onClick(() => {
            this.runTerm();
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text(this.termBusy ? '执行中…' : (this.termMsg.length > 0 ? this.termMsg : '就绪'))
          .fontSize(fsz(10)).fontColor(this.termBusy ? ACCENT : MUTED).layoutWeight(1).maxLines(1)
        Text('清屏')
          .fontSize(fsz(11)).fontColor(MUTED)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(8).backgroundColor(CARD)
          .onClick(() => {
            this.termOut = '';
          })
      }
      .width('100%')

      Scroll() {
        Text(this.termOut.length > 0 ? this.termOut : '$ 输入命令后回车，输出会累积在这里\n$ 支持 pwd / ls / cat / hidumper / dumpsys …')
          .fontSize(fsz(11))
          .fontFamily('monospace')
          .fontColor(this.termOut.length > 0 ? TEXT : MUTED)
          .width('100%')
          .textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .align(Alignment.TopStart)
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .padding(12)
      .backgroundColor(CARD)
      .borderRadius(14)
      .edgeEffect(EdgeEffect.Spring)

      if (this.termHist.length > 0) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.termHist.slice(0, 8), (h: string) => {
              Text(h)
                .fontSize(fsz(10)).fontColor(MUTED).fontFamily('monospace')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(CARD2).borderRadius(8)
                .onClick(() => {
                  this.termCmd = h;
                })
            }, (h: string, idx: number) => idx.toString() + h)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(30)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder ApiTab() {
    Scroll() {
      Column({ space: 12 }) {
        this.SectionTitle('本地 API 网关', '其它应用通过 HTTP 调用本机能力')

        Row({ space: 10 }) {
          Toggle({ type: ToggleType.Switch, isOn: this.apiOn })
            .selectedColor(ACCENT)
            .onChange((v: boolean) => {
              this.toggleApi(v);
            })
          Text(this.apiOn ? '运行中' : '已关闭')
            .fontSize(fsz(14)).fontColor(this.apiOn ? ACCENT : MUTED)
          Blank()
          TextInput({ text: $$this.apiPort })
            .type(InputType.Number).width(72).height(32).fontSize(fsz(12))
            .backgroundColor(CARD2).fontColor(TEXT).borderRadius(12)
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('高危端点', '权限最大的一条，默认关闭')
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Column({ space: 2 }) {
              Text('/v1/shell').fontSize(fsz(13)).fontColor(TEXT).fontFamily('monospace')
              Text('允许本机任意应用以 shell 身份执行命令')
                .fontSize(fsz(11)).fontColor(MUTED).maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.shellOn })
              .selectedColor(ACCENT)
              .onChange((v: boolean) => {
                this.shellOn = v;
                this.api.setShell(v);
                this.saveApi(this.apiOn);
                this.log('shell 端点 ' + (v ? '已开启' : '已关闭'));
              })
          }
          .width('100%')
          Text('关着的时候该端点直接返回错误，`/v1/capabilities` 也不会列出 shell。App 内的「终端」页不受此开关影响。')
            .fontSize(fsz(11)).fontColor(MUTED).width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)
        .width('100%')

        this.SectionTitle('网关地址', '仅监听 127.0.0.1，本机应用可直接访问')
        Column({ space: 8 }) {
          Text('http://127.0.0.1:' + this.apiPort)
            .fontSize(fsz(13)).fontColor(ACCENT).fontFamily('monospace').width('100%')
          Text('只绑定回环地址：其它 App 用本机 HTTP 直连即可，不需要电脑。需要电脑侧调用时用 hdc fport 把端口映射出来。')
            .fontSize(fsz(12)).fontColor(MUTED).width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)
        .width('100%')

        this.SectionTitle('访问令牌', '请求头 X-StarPivot-Token，除 /v1/ping 外全部校验')
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(this.token).fontSize(fsz(12)).fontColor(ACCENT).fontFamily('monospace').layoutWeight(1)
            Button('复制').height(32).fontSize(fsz(12))
              .backgroundColor(ACCENT_SOFT).fontColor(ACCENT).borderRadius(12)
              .onClick(() => {
                this.copyToken();
              })
          }
          .width('100%')

          Text(this.apiOn ? '令牌有效：外部请求必须带上这个头，否则返回 401。' : '先打开上面的开关，令牌才会生效。')
            .fontSize(fsz(12)).fontColor(MUTED).width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)
        .width('100%')

        Row({ space: 8 }) {
          Button('自测 /v1/ping').layoutWeight(1).height(50).fontSize(fsz(15)).fontWeight(FontWeight.Bold)
            .backgroundColor(ACCENT).fontColor(ON_ACCENT).borderRadius(12)
            .onClick(() => {
              this.selfTestApi();
            })
          Button('复制接入示例').layoutWeight(1).height(50).fontSize(fsz(15))
            .backgroundColor(Color.Transparent).fontColor(ACCENT).borderRadius(12)
            .border({ width: 1.5, color: ACCENT })
            .onClick(() => {
              this.copySample();
            })
        }

        if (this.apiMsg.length > 0) {
          this.Out(this.apiMsg, MUTED)
        }

        this.SectionTitle('接口清单', 'GET /v1/ping 免令牌，其余需令牌')
        Column({ space: 8 }) {
          this.ApiRow('GET', '/v1/ping', '健康检查（网关与 broker 是否在线）')
          this.ApiRow('GET', '/v1/capabilities', '能力清单与版本')
          this.ApiRow('GET', '/v1/device', '设备信息')
          this.ApiRow('POST', '/v1/shell', '{"cmd":"..."} 任意 shell 命令（需开「高危端点」开关）')
          this.ApiRow('POST', '/v1/screen/capture', '截屏，返回 base64 jpeg')
          this.ApiRow('POST', '/v1/screen/tap', '{"x":400,"y":1200}')
          this.ApiRow('POST', '/v1/screen/swipe', '{"x1":400,"y1":1500,"x2":400,"y2":600,"duration":400}')
          this.ApiRow('POST', '/v1/screen/key', '{"key":"Back"}')
          this.ApiRow('POST', '/v1/process/list', '进程列表')
          this.ApiRow('POST', '/v1/process/kill', '{"pid":1234}')
          this.ApiRow('POST', '/v1/file/list', '{"path":"/data/local/tmp"}')
          this.ApiRow('POST', '/v1/file/read', '{"path":"..."}')
          this.ApiRow('POST', '/v1/file/write', '{"path":"...","content":"..."}')
          this.ApiRow('POST', '/v1/file/remove', '{"path":"..."}')
          this.ApiRow('POST', '/v1/app/uninstall', '{"bundle":"..."}')
          this.ApiRow('POST', '/v1/app/start', '{"bundle":"..."}')
          this.ApiRow('POST', '/v1/app/list', '已安装应用')
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('调用示例', 'curl 与本机 ArkTS 各一份')
        this.Out('curl -X POST http://127.0.0.1:' + this.apiPort + '/v1/screen/tap \\\n'
          + '  -H "Content-Type: application/json" \\\n'
          + '  -H "X-StarPivot-Token: ' + this.token + '" \\\n'
          + '  -d \'{"x":400,"y":1200}\'', MUTED)
        this.Out('// ArkTS（另一个应用内）\n'
          + 'import { http } from \'@kit.NetworkKit\';\n'
          + 'const req = http.createHttp();\n'
          + 'const res = await req.request(\'http://127.0.0.1:' + this.apiPort + '/v1/process/list\', {\n'
          + '  method: http.RequestMethod.POST,\n'
          + '  header: { \'X-StarPivot-Token\': \'' + this.token + '\' }\n'
          + '});', MUTED)
        Row().height(16)
      }
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }

  @Builder AboutRow(k: string, v: string) {
    Row() {
      Text(k).fontSize(fsz(13)).fontColor(MUTED)
      Blank()
      Text(v).fontSize(fsz(13)).fontColor(TEXT).maxLines(2).textAlign(TextAlign.End).layoutWeight(1)
    }
    .width('100%')
  }

  @Builder KindRow(p: string, d: string) {
    Row() {
      Text(p).fontSize(fsz(12)).fontColor(ACCENT).fontFamily('monospace').layoutWeight(1)
      Text(d).fontSize(fsz(11)).fontColor(MUTED).textAlign(TextAlign.End).maxLines(2)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder AboutTab() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 14 }) {
          Column({ space: 6 }) {
            Row({ space: 10 }) {
              Text('星枢').fontSize(fsz(20)).fontWeight(FontWeight.Bold).fontColor(ACCENT)
              Text('StarPivot').fontSize(fsz(12)).fontColor(MUTED)
            }
            .alignItems(VerticalAlign.Bottom)
            Text('HDC 能力网关 · 免电脑直连 · uid=2000(shell)').fontSize(fsz(12)).fontColor(MUTED)
            Text('v' + (this.appVer.length > 0 ? this.appVer : '1.2.1 (1002001)') + ' · com.starpivot.xs').fontSize(fsz(11)).fontColor(MUTED)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Text('设置').fontSize(fsz(15)).fontWeight(FontWeight.Bold).fontColor(TEXT)
          Blank()
          Text('启动模式 · 接口 · 令牌').fontSize(fsz(12)).fontColor(MUTED)
          Text('›').fontSize(fsz(18)).fontColor(ACCENT)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 16, bottom: 16 })
        .backgroundColor(CARD)
        .borderRadius(18)
        .onClick(() => {
          this.showSettings = true;
        })

        this.SectionTitle('作者', '有问题欢迎联系')
        Column({ space: 12 }) {
          this.AboutRow('作者', '天狼星蚀')
          this.AboutRow('项目', 'StarPivot（星枢）')
          this.AboutRow('GitHub', 'xiotenstellar67')
          this.AboutRow('仓库', 'github.com/xiotenstellar67/StarPivot')
          this.AboutRow('QQ', '1806729469')
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('能力速览', '界面与接口共用同一套底层通道')
        Row({ space: 8 }) {
          this.CapCell('截屏', 'snapshot_display')
          this.CapCell('触控注入', 'uitest uiInput')
        }
        Row({ space: 8 }) {
          this.CapCell('进程管理', 'ps / kill')
          this.CapCell('文件读写', '/data/local/tmp')
        }
        Row({ space: 8 }) {
          this.CapCell('应用管理', 'aa start / bm uninstall')
          this.CapCell('按键事件', 'keyEvent')
        }

        this.SectionTitle('接口一览', 'HTTP · 仅监听 127.0.0.1:' + this.apiPort)
        Column({ space: 10 }) {
          this.KindRow('/v1/ping', '探活，免令牌')
          this.KindRow('/v1/capabilities', '能力清单')
          this.KindRow('/v1/device', '型号 / 品牌 / API / 系统版本')
          this.KindRow('/v1/shell', '任意 shell 命令')
          this.KindRow('/v1/screen/capture', '截屏，返回 base64 JPEG')
          this.KindRow('/v1/screen/tap', '点击注入 x,y')
          this.KindRow('/v1/screen/swipe', '滑动注入 x1,y1 → x2,y2')
          this.KindRow('/v1/screen/key', '按键事件 Back/Home 等')
          this.KindRow('/v1/process/list', '进程列表')
          this.KindRow('/v1/process/kill', '按 pid 结束进程')
          this.KindRow('/v1/file/list', '列目录')
          this.KindRow('/v1/file/read', '读文件')
          this.KindRow('/v1/file/write', '写文件')
          this.KindRow('/v1/file/remove', '删文件')
          this.KindRow('/v1/app/list', '应用列表（包名 + 中文名）')
          this.KindRow('/v1/app/start', '启动应用')
          this.KindRow('/v1/app/uninstall', '卸载应用')
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('技术实现', 'HDC 协议握手 + RSA-PSS 鉴权')
        Column({ space: 12 }) {
          this.AboutRow('传输', 'TCP 直连本机 hdcd 守护进程')
          this.AboutRow('端口', '扫描临时端口段 32768-60999 命中后记住')
          this.AboutRow('帧头', '11 字节 HW 头 + proto 头 + payload')
          this.AboutRow('鉴权', 'RSA-3072 密钥，PSS(MGF1-SHA512, salt=64) 签 nonce')
          this.AboutRow('身份', 'uid=2000(shell)，与电脑 hdc shell 同级')
          this.AboutRow('输出', 'protobuf 字段解包，大输出分帧增量缓冲')
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('运行信息', '当前会话')
        Column({ space: 12 }) {
          this.AboutRow('包名', 'com.starpivot.xs')
          this.AboutRow('构建批次', 'r4 · 底栏合并版 + 终端页 + shell 端点开关')
          this.AboutRow('版本', this.appVer.length > 0 ? this.appVer : '1.2.1 (1002001)')
          this.AboutRow('执行身份', this.ident.length > 0 ? this.ident : 'uid=2000(shell)')
          this.AboutRow('当前通道', this.brokerOk ? this.channel : '未连接')
          this.AboutRow('本机接口', 'http://127.0.0.1:' + this.apiPort)
          this.AboutRow('访问令牌', this.token.length > 12 ? (this.token.substring(0, 12) + '…') : this.token)
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('开源信息', 'MIT License')
        Column({ space: 12 }) {
          this.AboutRow('许可证', 'MIT')
          this.AboutRow('仓库', 'github.com/xiotenstellar67/StarPivot')
          this.AboutRow('作者', '天狼星蚀（xiotenstellar67）')
          this.AboutRow('构建', 'DevEco Studio + hvigor，SDK API 26')
          this.AboutRow('签名', '自带签名材料，或用 HoKit 在本机签未签名 HAP')
          this.AboutRow('依赖', '仅系统 Kit（NetworkKit / ArkUI / cryptoFramework）')
        }
        .width('100%')
        .padding(18)
        .backgroundColor(CARD)
        .borderRadius(18)

        this.SectionTitle('免责声明', '请在使用前阅读')
        Text('本软件通过 hdc 的 shell 通道（uid 2000）执行命令，能力边界与 shell 完全一致：可以读写 shell 有权访问的目录、结束进程、'
          + '安装卸载应用。它不是提权工具，也不会绕过系统权限模型。请在你自己拥有或已获授权的设备上使用，误操作（如删除系统文件、'
          + '结束关键进程）可能导致设备异常，风险由使用者承担。本机 HTTP 接口默认只监听回环地址，令牌泄露等于把 shell 权限交给同机应用，'
          + '请勿把令牌贴到公开场合。')
          .fontSize(fsz(12)).fontColor(MUTED).width('100%').lineHeight(19)

        this.SectionTitle('说明', '与 Android Shizuku 的对应关系')
        Text('Shizuku 在 Android 上通过 adb 派生的 shell 进程提供特权；本软件在鸿蒙上借用 hdc shell（uid 2000）执行同样的特权命令，'
          + '再把结果封装成本机 HTTP 接口给其它应用调用。权限边界与 shell 一致：能读写的目录、能操作的应用，都以 shell 的 uid 为准。')
          .fontSize(fsz(12)).fontColor(MUTED).width('100%').lineHeight(19)
        Row().height(16)
      }
      .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    }
    .scrollBar(BarState.Off)
    .layoutWeight(1)
  }

  @Builder SettingsPanel() {
    Column() {
      Row({ space: 12 }) {
        Text('设置').fontSize(fsz(19)).fontWeight(FontWeight.Bold).fontColor(TEXT)
        Blank()
        Button('关闭').height(36).fontSize(fsz(13))
          .backgroundColor(CARD).fontColor(ACCENT).borderRadius(10)
          .onClick(() => {
            this.showSettings = false;
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 12 })

      Scroll() {
        Column({ space: 12 }) {
          this.SectionTitle('启动模式', '决定请求走哪条通道')
          Row({ space: 8 }) {
            this.ModeChip('自动', 'auto')
            this.ModeChip('仅电脑', 'pc')
            this.ModeChip('仅本机', 'local')
          }
          .width('100%')

          Column({ space: 8 }) {
            this.AboutRow('自动', '优先电脑 broker，失败自动落到本机直连')
            this.AboutRow('仅电脑', '只走电脑端 broker（需要 PC 端脚本在线）')
            this.AboutRow('仅本机', '只走本机 hdcd，不需要电脑')
          }
          .width('100%')
          .padding(18)
          .backgroundColor(CARD)
          .borderRadius(18)

          this.SectionTitle('外观设置', '背景 · 高亮 · 字号 · 动画')
          Column({ space: 16 }) {
            Text('显示背景').fontSize(fsz(12)).fontColor(MUTED).width('100%')
            Row({ space: 10 }) {
              ForEach(BG_PRESETS, (p: BgPreset, i: number) => {
                Column({ space: 6 }) {
                  Row()
                    .width(46).height(30).borderRadius(10)
                    .backgroundColor(p.bg)
                    .border({ width: this.bgIdx === i ? 2 : 1, color: this.bgIdx === i ? ACCENT : LINE })
                  Text(p.name).fontSize(fsz(11)).fontColor(this.bgIdx === i ? ACCENT : MUTED)
                }
                .layoutWeight(1)
                .onClick(() => {
                  this.bgIdx = i;
                  this.applyLook();
                })
              }, (p: BgPreset) => p.name)
            }
            .width('100%')

            Text('高亮颜色').fontSize(fsz(12)).fontColor(MUTED).width('100%')
            Row({ space: 10 }) {
              ForEach(ACC_PRESETS, (p: AccPreset, i: number) => {
                Column({ space: 6 }) {
                  Row()
                    .width(46).height(30).borderRadius(10)
                    .backgroundColor(p.color)
                    .border({ width: this.accIdx === i ? 2 : 1, color: this.accIdx === i ? TEXT : LINE })
                  Text(p.name).fontSize(fsz(11)).fontColor(this.accIdx === i ? ACCENT : MUTED)
                }
                .layoutWeight(1)
                .onClick(() => {
                  this.accIdx = i;
                  this.applyLook();
                })
              }, (p: AccPreset) => p.name)
            }
            .width('100%')

            Text('字体大小').fontSize(fsz(12)).fontColor(MUTED).width('100%')
            Row({ space: 8 }) {
              this.FontChip('小', 0)
              this.FontChip('标准', 1)
              this.FontChip('大', 2)
            }
            .width('100%')

            Row() {
              Column({ space: 3 }) {
                Text('UI 动画').fontSize(fsz(13)).fontColor(TEXT)
                Text('切页签淡入、面板滑入、按压反馈').fontSize(fsz(11)).fontColor(MUTED)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.animOn })
                .selectedColor(ACCENT)
                .switchPointColor(ON_ACCENT)
                .onChange((v: boolean) => {
                  this.animOn = v;
                  this.saveUiCfg();
                  this.themeRev = this.themeRev + 1;
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(18)
          .backgroundColor(CARD)
          .borderRadius(18)

          this.SectionTitle('本机接口', '其它 App 通过 HTTP 调用')
          Column({ space: 12 }) {
            this.AboutRow('监听地址', '127.0.0.1:' + this.apiPort)
            this.AboutRow('访问令牌', this.token.length > 12 ? (this.token.substring(0, 12) + '…') : this.token)
            this.AboutRow('鉴权头', 'X-StarPivot-Token')
          }
          .width('100%')
          .padding(18)
          .backgroundColor(CARD)
          .borderRadius(18)

          this.SectionTitle('当前状态', '实时')
          Column({ space: 12 }) {
            this.AboutRow('通道', this.brokerOk ? this.channel : '未连接')
            this.AboutRow('hdcd 端口', this.hdcPort.length > 0 ? ('127.0.0.1:' + this.hdcPort) : '未探测')
            this.AboutRow('执行身份', this.ident.length > 0 ? this.ident : 'uid=2000(shell)')
          }
          .width('100%')
          .padding(18)
          .backgroundColor(CARD)
          .borderRadius(18)

          Row({ space: 8 }) {
            Button('重新检测').layoutWeight(1).height(46).fontSize(fsz(14)).fontWeight(FontWeight.Bold)
              .backgroundColor(ACCENT).fontColor(ON_ACCENT).borderRadius(12)
              .onClick(() => {
                this.checkBroker();
              })
            Button('完成').layoutWeight(1).height(46).fontSize(fsz(14))
              .backgroundColor(Color.Transparent).fontColor(ACCENT).borderRadius(12)
              .border({ width: 1.5, color: ACCENT })
              .onClick(() => {
                this.showSettings = false;
              })
          }
          .width('100%')
          Row().height(24)
        }
        .padding({ left: 16, right: 16, top: 4, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .transition(TransitionEffect.move(TransitionEdge.BOTTOM)
      .animation({ duration: this.animOn ? 260 : 1, curve: Curve.EaseOut })
      .combine(TransitionEffect.OPACITY.animation({ duration: this.animOn ? 200 : 1 })))
  }

  build() {
    Stack() {
      Column() {
        this.Header()

        Column() {
          if (this.curTab === 0) {
            this.OverviewTab()
          } else if (this.curTab === 1) {
            this.FuncTab()
          } else if (this.curTab === 2) {
            this.ApiTab()
          } else {
            this.AboutTab()
          }
        }
        .width('100%')
        .layoutWeight(1)
        .opacity(this.pageAlpha)

        Row() {
          this.TabItem(0, '概览')
          this.TabItem(1, '功能')
          this.TabItem(2, '接口')
          this.TabItem(3, '关于')
        }
        .width('100%')
        .height(58)
        .backgroundColor(CARD)
        .border({ width: { top: 1 }, color: LINE })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      // 读一下 themeRev：外观设置变更时整页重建，色板与字号才会生效
      .backgroundColor(this.themeRev >= 0 ? BG : BG)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.showSettings) {
        this.SettingsPanel()
      }
    }
    .width('100%')
    .height('100%')
    // 侧栏宽度跟窗口宽度走：手机窄一点、平板保持 132，分屏/旋转时也会重算
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: number = Number(newArea.width);
      if (w > 0) {
        const next: number = w < 360 ? 80 : (w < 600 ? 92 : 132);
        if (next !== this.sideW) {
          this.sideW = next;
        }
      }
    })
  }
}

