import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { ExecResult, HealthInfo, ProcessItem } from './Broker';
import { Gateway } from './Gateway';

/**
 * 星zuku 本地 API 网关。
 * 三方应用 POST 到 http://127.0.0.1:<port>/v1/xxx，
 * 头部 X-StarPivot-Token 必须与 App 内展示的令牌一致。
 */

interface ReqBody {
  cmd?: string;
  path?: string;
  content?: string;
  bundle?: string;
  key?: string;
  pid?: number;
  x?: number;
  y?: number;
  x1?: number;
  y1?: number;
  x2?: number;
  y2?: number;
  duration?: number;
  width?: number;
  height?: number;
  text?: string;
  replace?: boolean;
  count?: number;
  type?: string;
  domain?: string;
  name?: string;
  mode?: string;
  delay?: number;
  gap?: number;
  off?: boolean;
  id?: string;
  url?: string;
}

export class ApiServer {
  private srv: socket.TCPSocketServer | null = null;
  private token: string = '';
  private port: number = 0;
  private logger: (msg: string) => void = (msg: string) => {
  };
  /** 请求串行队列，保证同一时刻只跑一条命令 */
  private queue: Promise<void> = Promise.resolve();
  isRunning: boolean = false;
  /** /v1/shell 开关，默认关：这条端点等于把 shell 借给任何拿到令牌的本机应用 */
  private shellOn: boolean = false;

  setShell(on: boolean): void {
    this.shellOn = on;
  }

  isShellOn(): boolean {
    return this.shellOn;
  }

  setLogger(fn: (msg: string) => void): void {
    this.logger = fn;
  }

  getPort(): number {
    return this.port;
  }

  getToken(): string {
    return this.token;
  }

  /** 对外报的版本号也从包信息读，别在协议里写死 1.2.0 */
  private ver(): string {
    try {
      return bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      return '1.2.1';
    }
  }

  async start(port: number, token: string): Promise<void> {
    if (this.isRunning) {
      return;
    }
    const s: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    await s.listen({ address: '127.0.0.1', port: port });
    s.on('connect', (client: socket.TCPSocketConnection) => {
      this.serve(client);
    });
    this.srv = s;
    this.port = port;
    this.token = token;
    this.isRunning = true;
    this.logger('API 网关已监听 127.0.0.1:' + port);
  }

  async stop(): Promise<void> {
    if (this.srv !== null) {
      try {
        await this.srv.close();
      } catch (e) {
      }
      this.srv = null;
      this.isRunning = false;
      this.logger('API 网关已停止');
    }
  }

  private serve(client: socket.TCPSocketConnection): void {
    let buf: string = '';
    let done: boolean = false;
    const dec: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    // 兜底关连接：半截请求（只发 header 不发 body）或空了连的客户端不能一直占着 fd
    setTimeout(() => {
      if (!done) {
        done = true;
        try {
          client.close();
        } catch (e) {
        }
      }
    }, 15000);
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (done) {
        return;
      }
      try {
        buf += dec.decodeToString(new Uint8Array(info.message));
      } catch (e) {
        return;
      }
      // 上限保护：本机恶意客户端灌大包时不至于把进程内存吃穿
      if (buf.length > 3 * 1024 * 1024) {
        done = true;
        this.reply(client, 413, '{"ok":false,"error":"request too large"}');
        return;
      }
      const headEnd: number = buf.indexOf('\r\n\r\n');
      if (headEnd < 0) {
        if (buf.length > 64 * 1024) {
          done = true;
          try {
            client.close();
          } catch (e) {
          }
        }
        return;
      }
      const lines: string[] = buf.substring(0, headEnd).split('\r\n');
      let contentLength: number = 0;
      let reqToken: string = '';
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i];
        const p: number = line.indexOf(':');
        if (p <= 0) {
          continue;
        }
        const name: string = line.substring(0, p).trim().toLowerCase();
        const value: string = line.substring(p + 1).trim();
        if (name === 'content-length') {
          const n: number = parseInt(value, 10);
          // parseInt 失败会给 NaN，直接参与比较和 substring 会静默错位
          contentLength = (isNaN(n) || n < 0) ? 0 : n;
        } else if (name === 'x-starpivot-token') {
          reqToken = value;
        }
      }
      if (buf.length - (headEnd + 4) < contentLength) {
        return;
      }
      done = true;
      const firstLine: string[] = lines[0].split(' ');
      const method: string = firstLine.length > 0 ? firstLine[0] : 'GET';
      const path: string = firstLine.length > 1 ? firstLine[1] : '/';
      const body: string = buf.substring(headEnd + 4, headEnd + 4 + contentLength);
      this.dispatch(client, method, path, body, reqToken);
    });
  }

  private dispatch(client: socket.TCPSocketConnection, method: string, path: string,
                   body: string, token: string): void {
    this.logger('请求 ' + method + ' ' + path);
    // 全部请求排队串行：底层 hdcd 会话只有一条，并发会让回包错位、甚至卡死整条通道
    const job: () => Promise<void> = async (): Promise<void> => {
      try {
        const payload: string = await this.route(method, path, body, token);
        const code: number = payload.indexOf('"code":401') >= 0 ? 401 : 200;
        this.reply(client, code, payload);
      } catch (e) {
        this.logger('路由异常: ' + JSON.stringify(e));
        this.reply(client, 500, '{"ok":false,"error":"internal error"}');
      }
    };
    this.queue = this.queue.then(job, job);
  }

  private reply(client: socket.TCPSocketConnection, code: number, payload: string): void {
    const bodyBytes: Uint8Array = new util.TextEncoder().encodeInto(payload);
    const head: string = 'HTTP/1.1 ' + code + ' ' + (code === 200 ? 'OK' : (code === 401 ? 'Unauthorized' : 'Error')) + '\r\n' +
      'Content-Type: application/json; charset=utf-8\r\n' +
      'Access-Control-Allow-Origin: *\r\n' +
      'Access-Control-Allow-Headers: *\r\n' +
      'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n' +
      'Content-Length: ' + bodyBytes.length + '\r\n' +
      'Connection: close\r\n\r\n';
    client.send({ data: head + payload }).then(() => {
      client.close();
    }).catch(() => {
      try {
        client.close();
      } catch (e) {
      }
    });
  }

  private async route(method: string, path: string, body: string, token: string): Promise<string> {
    if (method === 'OPTIONS') {
      return '{"ok":true}';
    }
    if (path !== '/v1/ping' && token !== this.token) {
      return '{"ok":false,"code":401,"error":"unauthorized: X-StarPivot-Token 不匹配"}';
    }
    let req: ReqBody = {};
    if (body.length > 0) {
      try {
        req = JSON.parse(body) as ReqBody;
      } catch (e) {
        return '{"ok":false,"code":400,"error":"body 不是合法 JSON"}';
      }
    }

    if (path === '/v1/ping') {
      const h: HealthInfo | null = await Gateway.health();
      const online: boolean = h !== null;
      return '{"ok":true,"service":"starpivot","version":"' + this.ver() + '","port":' + this.port +
        ',"broker":' + (online ? 'true' : 'false') + '}';
    }
    if (path === '/v1/capabilities') {
      const shellCap: string = this.shellOn ? '"shell",' : '';
      return '{"ok":true,"caps":["device","device.udid","device.storage","device.top",' + shellCap
        + '"screen.capture","screen.tap","screen.swipe","screen.key","screen.text","ui.dump",'
        + '"net.sockets","process.list","process.kill","file.list","file.read","file.write","file.remove",'
        + '"app.list","app.detail","app.start","app.stop","app.install","app.uninstall","app.clean",'
        + '"log.events","log.hilog","screen.wake","screen.unlock",'
        + '"log.crash","log.crashDetail","device.memory","device.cpu","net.iface","net.traffic","process.detail",'
        + '"device.cpufreq","device.cluster","app.shared","app.patch","net.http"]}';
    }
    if (path === '/v1/device') {
      const r: ExecResult = await Gateway.deviceInfo();
      return this.execJson(r);
    }
    if (path === '/v1/shell') {
      if (!this.shellOn) {
        return '{"ok":false,"error":"shell 端点未开启：请在 App 的「接口」页打开「允许第三方应用执行 shell」"}';
      }
      const cmd: string = req.cmd === undefined ? '' : req.cmd;
      if (cmd.length === 0) {
        return '{"ok":false,"error":"缺少 cmd"}';
      }
      // 审计：谁在什么时候执行了什么，只记前 120 字符，避免日志被长命令撑爆
      this.logger('shell 调用: ' + cmd.substring(0, 120));
      const r: ExecResult = await Gateway.exec(cmd, 30000);
      return this.execJson(r);
    }
    if (path === '/v1/screen/capture') {
      // 可选 width / height：默认 1600 宽，高度按屏幕比例；传 0 表示原分辨率 / 按比例
      const w: number = req.width === undefined ? 1600 : req.width;
      const h: number = req.height === undefined ? 0 : req.height;
      const b64: string = await Gateway.capture(w, h);
      if (b64.length === 0) {
        return '{"ok":false,"error":"截屏失败"}';
      }
      return '{"ok":true,"mime":"image/jpeg","base64":' + JSON.stringify(b64) + '}';
    }
    if (path === '/v1/screen/tap') {
      const r: ExecResult = await Gateway.tap(req.x === undefined ? 0 : req.x, req.y === undefined ? 0 : req.y);
      return this.execJson(r);
    }
    if (path === '/v1/screen/swipe') {
      const r: ExecResult = await Gateway.swipe(
        req.x1 === undefined ? 0 : req.x1, req.y1 === undefined ? 0 : req.y1,
        req.x2 === undefined ? 0 : req.x2, req.y2 === undefined ? 0 : req.y2,
        req.duration === undefined ? 300 : req.duration);
      return this.execJson(r);
    }
    if (path === '/v1/screen/key') {
      const k: string = req.key === undefined ? 'Back' : req.key;
      const r: ExecResult = await Gateway.keyEvent(k);
      return this.execJson(r);
    }
    if (path === '/v1/screen/text') {
      const t: string = req.text === undefined ? '' : req.text;
      if (t.length === 0) {
        return '{"ok":false,"error":"缺少 text"}';
      }
      const r: ExecResult = await Gateway.inputText(t);
      return this.execJson(r);
    }
    if (path === '/v1/ui/dump') {
      const r: ExecResult = await Gateway.dumpUi();
      if (r.code !== 0) {
        return this.execJson(r);
      }
      return '{"ok":true,"size":' + String(r.out.length) + ',"json":' + JSON.stringify(r.out) + '}';
    }
    if (path === '/v1/net/sockets') {
      const r: ExecResult = await Gateway.sockets();
      if (r.code !== 0) {
        return this.execJson(r);
      }
      return this.socketsJson(r.out);
    }
    if (path === '/v1/process/list') {
      const r: ExecResult = await Gateway.processText();
      if (r.code !== 0) {
        return this.execJson(r);
      }
      const items: ProcessItem[] = Gateway.parseProcess(r.out);
      return '{"ok":true,"count":' + items.length + ',"items":' + JSON.stringify(items) + '}';
    }
    if (path === '/v1/process/kill') {
      const r: ExecResult = await Gateway.killProcess(req.pid === undefined ? 0 : req.pid);
      return this.execJson(r);
    }
    if (path === '/v1/file/list') {
      const r: ExecResult = await Gateway.listDir(req.path === undefined ? '/data/local/tmp' : req.path);
      return this.execJson(r);
    }
    if (path === '/v1/file/read') {
      const r: ExecResult = await Gateway.readFile(req.path === undefined ? '' : req.path);
      return this.execJson(r);
    }
    if (path === '/v1/file/write') {
      const r: ExecResult = await Gateway.writeFile(req.path === undefined ? '' : req.path,
        req.content === undefined ? '' : req.content);
      return this.execJson(r);
    }
    if (path === '/v1/file/remove') {
      const r: ExecResult = await Gateway.removeFile(req.path === undefined ? '' : req.path);
      return this.execJson(r);
    }
    if (path === '/v1/app/uninstall') {
      const r: ExecResult = await Gateway.uninstall(req.bundle === undefined ? '' : req.bundle);
      return this.execJson(r);
    }
    if (path === '/v1/app/start') {
      const r: ExecResult = await Gateway.startApp(req.bundle === undefined ? '' : req.bundle);
      return this.execJson(r);
    }
    if (path === '/v1/app/list') {
      const r: ExecResult = await Gateway.appList();
      return this.execJson(r);
    }
    if (path === '/v1/app/detail') {
      const b: string = req.bundle === undefined ? '' : req.bundle;
      if (b.length === 0) {
        return '{"ok":false,"error":"缺少 bundle"}';
      }
      const r: ExecResult = await Gateway.appDetail(b);
      if (r.code !== 0) {
        return this.execJson(r);
      }
      return '{"ok":true,"bundle":' + JSON.stringify(b) + ',"size":' + String(r.out.length) +
        ',"json":' + JSON.stringify(r.out) + '}';
    }
    if (path === '/v1/app/install') {
      const p: string = req.path === undefined ? '' : req.path;
      if (p.length === 0) {
        return '{"ok":false,"error":"缺少 path（设备上已签名 HAP 的路径）"}';
      }
      const r: ExecResult = await Gateway.install(p, req.replace === true);
      return this.execJson(r);
    }
    if (path === '/v1/app/stop') {
      const b: string = req.bundle === undefined ? '' : req.bundle;
      if (b.length === 0) {
        return '{"ok":false,"error":"缺少 bundle"}';
      }
      const r: ExecResult = await Gateway.forceStop(b);
      return this.execJson(r);
    }
    if (path === '/v1/device/params') {
      const r: ExecResult = await Gateway.sysParams();
      return this.execJson(r);
    }
    if (path === '/v1/device/storage') {
      const r: ExecResult = await Gateway.storage();
      return this.execJson(r);
    }
    if (path === '/v1/device/top') {
      const r: ExecResult = await Gateway.topSnapshot();
      return this.execJson(r);
    }
    if (path === '/v1/device/udid') {
      const r: ExecResult = await Gateway.udid();
      return this.execJson(r);
    }
    if (path === '/v1/app/clean') {
      const b: string = req.bundle === undefined ? '' : req.bundle;
      if (b.length === 0) {
        return '{"ok":false,"error":"缺少 bundle"}';
      }
      const m: string = req.mode === undefined ? 'cache' : req.mode;
      const r: ExecResult = await Gateway.cleanBundle(b, m);
      return this.execJson(r);
    }
    if (path === '/v1/log/events') {
      const t: string = req.type === undefined ? '' : req.type;
      const d: string = req.domain === undefined ? '' : req.domain;
      const n: string = req.name === undefined ? '' : req.name;
      const c: number = req.count === undefined ? 20 : req.count;
      const r: ExecResult = await Gateway.sysEvents(t, d, n, c);
      return this.execJson(r);
    }
    if (path === '/v1/log/hilog') {
      const c: number = req.count === undefined ? 200 : req.count;
      const r: ExecResult = await Gateway.hilogTail(c);
      return this.execJson(r);
    }
    if (path === '/v1/screen/wake') {
      const r: ExecResult = await Gateway.wake();
      return this.execJson(r);
    }
    if (path === '/v1/screen/unlock') {
      // 安全约束：PIN 只能来自本机保存，不接受任何入参传入
      const pin: string = Gateway.localPin();
      if (pin.length === 0) {
        return '{"ok":false,"error":"本机未保存 PIN，请先在 App 的「解锁」页设置"}';
      }
      const delay: number = req.delay === undefined ? 800 : req.delay;
      const gap: number = req.gap === undefined ? 300 : req.gap;
      const off: boolean = req.off === undefined ? false : req.off;
      const d = display.getDefaultDisplaySync();
      const r: ExecResult = await Gateway.unlock(pin, delay, gap, d.width, d.height, off);
      return this.execJson(r);
    }
    if (path === '/v1/log/crash') {
      const r: ExecResult = await Gateway.crashList();
      return this.execJson(r);
    }
    if (path === '/v1/log/crashDetail') {
      const id: string = req.id === undefined ? '' : req.id;
      const r: ExecResult = await Gateway.crashDetail(id);
      return this.execJson(r);
    }
    if (path === '/v1/device/memory') {
      const r: ExecResult = await Gateway.memDump();
      return this.execJson(r);
    }
    if (path === '/v1/device/cpu') {
      const r: ExecResult = await Gateway.cpuDump();
      return this.execJson(r);
    }
    if (path === '/v1/device/cpufreq') {
      const r: ExecResult = await Gateway.cpuFreq();
      return this.execJson(r);
    }
    if (path === '/v1/device/cluster') {
      const r: ExecResult = await Gateway.sysCluster();
      return this.execJson(r);
    }
    if (path === '/v1/app/shared') {
      const r: ExecResult = await Gateway.sharedLibs();
      return this.execJson(r);
    }
    if (path === '/v1/app/patch') {
      const b: string = req.bundle === undefined ? '' : req.bundle;
      if (b.length === 0) {
        return '{"ok":false,"error":"缺少 bundle"}';
      }
      const r: ExecResult = await Gateway.quickFix(b);
      return this.execJson(r);
    }
    if (path === '/v1/net/http') {
      const u: string = req.url === undefined ? '' : req.url;
      if (u.length === 0) {
        return '{"ok":false,"error":"缺少 url"}';
      }
      const r: ExecResult = await Gateway.httpFetch(u);
      return this.execJson(r);
    }
    if (path === '/v1/net/iface') {
      const r: ExecResult = await Gateway.ifaces();
      return this.execJson(r);
    }
    if (path === '/v1/net/traffic') {
      const r: ExecResult = await Gateway.netTraffic();
      return this.execJson(r);
    }
    if (path === '/v1/process/detail') {
      const pid: number = req.pid === undefined ? 0 : req.pid;
      if (pid <= 0) {
        return '{"ok":false,"error":"缺少 pid"}';
      }
      const r: ExecResult = await Gateway.procDetail(pid);
      return this.execJson(r);
    }
    return '{"ok":false,"error":"unknown endpoint"}';
  }

  /** netstat -an 的行式输出 → 结构化套接字列表 */
  private socketsJson(text: string): string {
    const lines: string[] = text.split('\n');
    const items: string[] = [];
    const listeners: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const raw: string[] = line.split(' ');
      const t: string[] = [];
      for (let k = 0; k < raw.length; k++) {
        if (raw[k].length > 0) {
          t.push(raw[k]);
        }
      }
      if (t.length < 5) {
        continue;
      }
      const proto: string = t[0];
      if (proto !== 'tcp' && proto !== 'tcp6' && proto !== 'udp' && proto !== 'udp6') {
        continue;
      }
      const local: string = t[3];
      const remote: string = t[4];
      const state: string = t.length > 5 ? t[5] : '';
      const c: number = local.lastIndexOf(':');
      const port: number = c >= 0 ? Number.parseInt(local.substring(c + 1), 10) : 0;
      const obj: string = '{"proto":' + JSON.stringify(proto) + ',"local":' + JSON.stringify(local) +
        ',"port":' + String(port) + ',"remote":' + JSON.stringify(remote) +
        ',"state":' + JSON.stringify(state) + '}';
      items.push(obj);
      if (state.indexOf('LISTEN') === 0) {
        listeners.push(obj);
      }
    }
    return '{"ok":true,"count":' + String(items.length) + ',"listeners":[' + listeners.join(',') +
      '],"sockets":[' + items.join(',') + ']}';
  }

  private execJson(r: ExecResult): string {
    return '{"ok":' + (r.code === 0 ? 'true' : 'false') + ',"code":' + r.code +
      ',"out":' + JSON.stringify(r.out) + ',"err":' + JSON.stringify(r.err) + '}';
  }
}

