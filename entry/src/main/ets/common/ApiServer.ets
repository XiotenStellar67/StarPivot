import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
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

  setLogger(fn: (msg: string) => void): void {
    this.logger = fn;
  }

  getPort(): number {
    return this.port;
  }

  getToken(): string {
    return this.token;
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
    client.on('message', (info: socket.SocketMessageInfo) => {
      if (done) {
        return;
      }
      try {
        buf += dec.decodeToString(new Uint8Array(info.message));
      } catch (e) {
        return;
      }
      const headEnd: number = buf.indexOf('\r\n\r\n');
      if (headEnd < 0) {
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
          contentLength = parseInt(value);
        } else if (name === 'x-starpivot-token' || name === 'X-StarPivot-Token') {
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
      return '{"ok":true,"service":"starpivot","version":"1.1.0","port":' + this.port +
        ',"broker":' + (online ? 'true' : 'false') + '}';
    }
    if (path === '/v1/capabilities') {
      return '{"ok":true,"caps":["device","shell","screen.capture","screen.tap","screen.swipe","screen.key",'
        + '"process.list","process.kill","file.list","file.read","file.write","file.remove",'
        + '"app.uninstall","app.start","app.list"]}';
    }
    if (path === '/v1/device') {
      const r: ExecResult = await Gateway.deviceInfo();
      return this.execJson(r);
    }
    if (path === '/v1/shell') {
      const cmd: string = req.cmd === undefined ? '' : req.cmd;
      if (cmd.length === 0) {
        return '{"ok":false,"error":"缺少 cmd"}';
      }
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
    return '{"ok":false,"error":"unknown endpoint"}';
  }

  private execJson(r: ExecResult): string {
    return '{"ok":' + (r.code === 0 ? 'true' : 'false') + ',"code":' + r.code +
      ',"out":' + JSON.stringify(r.out) + ',"err":' + JSON.stringify(r.err) + '}';
  }
}

