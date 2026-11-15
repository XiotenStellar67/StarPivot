# 星枢 StarPivot

**鸿蒙版 Shizuku：把 HDC 的 shell 能力封装成本机 HTTP 接口，供其它应用调用。**

星枢在你的鸿蒙设备上以 `uid=2000(shell)` 的身份执行截屏、触控注入、进程管理、文件读写、应用启停等操作，
并把它们包装成一组带令牌鉴权的 `http://127.0.0.1:18790/v1/*` 接口 —— 任何同设备上的应用都能调用，
不需要 root，也不需要每台设备刷机。

- 包名：`com.starpivot.xs`
- 版本：1.2.0
- 平台：HarmonyOS（Stage 模型 / ArkTS / SDK API 26）
- 许可证：MIT

> 仅在你**自己的设备**上使用。本项目的全部能力都建立在「设备用户主动开启开发者模式并授权调试」这个前提上，
> 不要用它去操作不属于你的设备。

---

## 一、它解决什么问题

HarmonyOS 三方应用跑在自己的沙箱 uid 里，**不能**自己 fork 出 `hdc`，也不能以 `shell` 身份跑系统命令。
所以想要「读别人应用目录、杀进程、截屏、模拟点击」这类能力，就必须先拿到一个 `uid=2000(shell)` 的执行通道。

星枢做两件事：

1. **拿到 shell 通道** —— 提供两种互斥的通道实现（见下节）；
2. **把它变成 API** —— 在设备回环地址上开一个 HTTP 服务，用令牌鉴权，把常用操作固化成一堆稳定接口。

跟 Android 上的 Shizuku 是同构的思路：Shizuku 靠 ADB 拉起一个 shell 进程并通过 binder 分发，
星枢靠 HDC 协议与 `hdcd` 对话，再通过 HTTP 分发。

---

## 二、两种通道

### 1. 免电脑直连（推荐，默认）

鸿蒙设备的开发者模式下，系统自带一个 `hdcd` 守护进程，监听本机回环上的一个端口（实测为 `46751`，
即 `/proc/net/tcp` 里的十六进制 `B69F`），它的权限就是 `uid=2000(shell)`。

星枢在本进程内直接和这个端口做 **HDCF 帧协议握手**，并用应用自己生成的 RSA-3072 密钥完成鉴权：

```
App (ArkTS TCPSocket)
   │  帧头 11 字节：HW 00 00 01 00 | protoLen | 00 | payloadLen
   │  proto 头：08 ch 10 cmd 18 00 20 09
   │  payload 字段：1=OHOS HDC, 2=state, 3=ts, 4=target, 5=auth, 6=Ver
   ▼
127.0.0.1:<hdcd 端口>  ← 端口不固定，启动时在候选端口里逐个探测 hello 横幅
   ▼
uid=2000(shell) 执行命令，stdout 按帧回传
```

鉴权算法：`RSA-PSS(MGF1-SHA512, saltLen=64)` over `SHA512(nonce)`，密钥对在应用内生成并持久化。
这条路径**完全不需要电脑**，插不插 USB 都能用。

几个工程上的坑（已在本仓库内修复，供后来者参考）：

- `on('message'/'close'/'error')` 必须在 `connect()` 成功之后才能挂载；
- `util.TextEncoder.encodeInto()` 对长串会返回 `undefined`，所以自己写了 `encodeUtf8()`；
- hello 回复的 `state` 字段**不可靠**（实测既有 `state=0` 也有 `state=3`），只能按横幅文本判定；
- 所有 socket/缓冲状态是全局的，并发建连会把在途回包冲掉，因此连接做了单飞 + 互斥锁，读帧做了增量缓冲。

### 2. 电脑 broker（兼容旧路径）

插着电脑时，也可以用 `pc-broker/broker.js`：App 通过 `hdc rport` 反向映射访问电脑上的 Node 服务，
由电脑调用 `hdc shell` 执行命令。适合调试或 hdcd 不可用的场景。

App 里有三态开关：`自动`（优先 broker，失败回落本机）/ `仅电脑` / `仅本机`，默认 `自动`。

---

## 三、界面

底栏 7 页签：**概览 / 屏幕 / 进程 / 文件 / 应用 / 接口 / 关于**

- **屏幕**：截屏（可自定义输出分辨率，宽/高各一个输入框，0 = 原分辨率 / 按比例），支持一键存相册、点击/滑动/按键注入
- **进程**：进程列表 + 结束进程
- **文件**：目录浏览、搜索、按后缀识别预览文本/图片、写入、删除
- **应用**：图形化应用列表（中文名优先，小字显示包名）、启动、卸载
- **接口**：开关本机 HTTP 服务、端口与令牌管理、接口自检
- **关于**：能力速览、外观入口、运行信息、开源信息

设置面板里包含：启动模式切换、**外观设置**（背景 5 档 / 高亮 6 档 / 字号 3 档 / UI 动画开关）、本机接口信息。

---

## 四、HTTP 接口

服务监听 `127.0.0.1:18790`（端口可改）。除 `/v1/ping` 外，所有请求都要带令牌头：

```
X-StarPivot-Token: <App「接口」页显示的 24 位十六进制令牌>
```

完整的协议细节、字段表、错误语义、超时建议、并发策略和排查表见
**[docs/开发者接口文档.md](docs/开发者接口文档.md)**。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/ping` | 健康检查，无需令牌 |
| POST | `/v1/capabilities` | 列出设备支持的能力 |
| POST | `/v1/device` | 设备信息（型号 / 系统版本 / 序列号等） |
| POST | `/v1/shell` | 直接执行自定义命令，返回 stdout |
| POST | `/v1/screen/capture` | 截屏，返回 base64 JPEG。可选 `width`/`height`（px，0 = 原分辨率/按比例） |
| POST | `/v1/screen/tap` | 点击坐标 `x`,`y` |
| POST | `/v1/screen/swipe` | 滑动 `x1`,`y1`,`x2`,`y2` |
| POST | `/v1/screen/key` | 按键注入 |
| POST | `/v1/process/list` | 进程列表 |
| POST | `/v1/process/kill` | 结束进程 |
| POST | `/v1/file/list` | 目录列表（结构化） |
| POST | `/v1/file/read` | 读文件 |
| POST | `/v1/file/write` | 写文件 |
| POST | `/v1/file/remove` | 删除文件 |
| POST | `/v1/app/list` | 应用列表 |
| POST | `/v1/app/start` | 启动应用 |
| POST | `/v1/app/uninstall` | 卸载应用 |

示例：

```bash
curl -X POST http://127.0.0.1:18790/v1/ping

curl -X POST http://127.0.0.1:18790/v1/screen/capture \
  -H "X-StarPivot-Token: <令牌>" -H "Content-Type: application/json" \
  -d '{"width":1600}'
```

---

## 五、构建

要求：**DevEco Studio**（含 HarmonyOS SDK，API 26）+ Node（DevEco 自带即可）。

```powershell
# Windows：脚本会自动定位 DevEco 的 node / hvigor / JDK
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（**未签名**）。

也可以直接用 DevEco Studio 打开本目录构建。注意 `local.properties` 里的 `sdk.dir` 要改成你自己机器上的 SDK 路径
（该文件已被 `.gitignore` 排除，需自己创建，或让 DevEco 打开工程时自动生成）。

> 工程路径**不要带中文或空格**：hvigor 在含中文的目录下会报 `Invalid project path` 直接失败。
> 放在 `D:\code\StarPivot` 这类纯英文路径是安全的。

> 构建脚本里把 DevEco 自带的 JDK 放到 PATH 最前，是因为本机 PATH 上的 Oracle JDK 8 会让
> `app_packing_tool.jar` 崩溃（0xC0000409）。如果你机器上没这问题，直接用 IDE 构建也行。

---

## 六、签名与安装

仓库**不提供任何签名材料**，也不推荐把签名证书提交进版本库。原因是 HAP 的签名必须和
你设备的调试授权绑定，别人的证书签出来的包你装不上。

推荐做法：把构建出来的**未签名 HAP** 用平板上的签名工具（例如 HoKit）在本机签名后安装。
你也可以在 DevEco Studio 里用「自动签名」（登录华为账号 + 真机连接）生成自己的调试证书。

> 这也是本项目的一个设计取向：不做「App 内登录账号换签名」「App 内一键安装」，签名这件事始终留在用户手里。

---

## 七、目录

```
StarPivot/
├─ AppScope/                 应用级配置（bundleName / 版本 / 图标）
├─ entry/                    主模块
│  └─ src/main/ets/
│     ├─ common/
│     │  ├─ LocalHdc.ets     HDCF 帧协议 + RSA-PSS 鉴权 + 端口探测 + 命令执行
│     │  ├─ Gateway.ets      能力层（resolve / exec / capture / 文件 / 应用）
│     │  ├─ ApiServer.ets    本机 HTTP 服务，17 条 /v1/* 路由
│     │  └─ Broker.ets       电脑 broker 客户端
│     ├─ pages/Index.ets     全部 UI（7 页签 + 设置面板 + 外观设置）
│     └─ entryability/       Ability 入口
├─ pc-broker/                电脑端 Node broker（可选）
├─ docs/
│  └─ 开发者接口文档.md       协议/字段/错误/示例/排查（调用方必读）
├─ build.ps1                 命令行构建脚本
└─ LICENSE                   MIT
```

---

## 八、已知限制

- `hdcd` 端口不固定且会随重启变化，靠候选端口 + hello 探测定位；极端情况下可能探测不到，需要重试
- `uid=2000` 读不到 `const.product.sn`（`param get` 返回 `errNum 106`），序列号靠回退显示
- 设备锁屏时无法远程解锁（属系统安全限制）
- 电脑 broker 方式在拔线后需重新 `hdc rport`
- 应用图标目前是自绘图标，仓库内未附带第三方素材

---

## 九、致谢与联系

- 作者：**天狼星蚀**
- GitHub：[@xiotenstellar67](https://github.com/xiotenstellar67)
- QQ：1806729469

思路来自 Android 的 [Shizuku](https://github.com/RikkaApps/Shizuku)，但实现上完全基于鸿蒙 HDC 协议，与 Shizuku 无代码关联。

## License

MIT © 2026 天狼星蚀
