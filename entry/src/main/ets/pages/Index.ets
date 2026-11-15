import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { ApiServer } from '../common/ApiServer';
import { ExecResult, ProcessItem } from '../common/Broker';
import { Gateway } from '../common/Gateway';
import { LocalHdc } from '../common/LocalHdc';

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
  @State token: string = '';
  @State apiMsg: string = '';

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
    this.checkBroker();
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

  private restoreApi(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const store = preferences.getPreferencesSync(ctx, { name: 'starpivot' });
      const p = store.getSync('apiPort', 18790) as number;
      if (p > 0) {
        this.apiPort = '' + p;
      }
      const wasOn = store.getSync('apiOn', false) as boolean;
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
      if (index === 2 && this.processes.length === 0) {
        this.loadProcess();
      }
      if (index === 3 && this.fileItems.length === 0) {
        this.loadDir();
      }
      if (index === 4 && this.apps.length === 0) {
        this.doAppList();
      }
    })
  }

  @Builder Header() {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text('StarPivot').fontSize(fsz(18)).fontWeight(FontWeight.Bold).fontColor(ACCENT)
        Text('星枢 · HDC 能力网关').fontSize(fsz(12)).fontColor(MUTED)
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
          this.ApiRow('POST', '/v1/shell', '{"cmd":"..."} 任意 shell 命令')
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
            Text('v1.2.0 · build 1002000 · com.starpivot.xs').fontSize(fsz(11)).fontColor(MUTED)
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
          this.AboutRow('版本', '1.2.0 (1002000)')
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
            this.ScreenTab()
          } else if (this.curTab === 2) {
            this.ProcessTab()
          } else if (this.curTab === 3) {
            this.FileTab()
          } else if (this.curTab === 4) {
            this.AppTab()
          } else if (this.curTab === 5) {
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
          this.TabItem(1, '屏幕')
          this.TabItem(2, '进程')
          this.TabItem(3, '文件')
          this.TabItem(4, '应用')
          this.TabItem(5, '接口')
          this.TabItem(6, '关于')
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
  }
}

