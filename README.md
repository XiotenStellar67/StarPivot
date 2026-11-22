# StarPivot · 星枢

> 把 HarmonyOS 的 **HDC / hdc shell（设备端 uid=2000 shell）** 能力封装成一套本地 HTTP 接口，
> 供设备上的其它应用调用；同时自带图形界面，可直接操作截屏、进程、文件、应用与诊断。

**包名** `com.starpivot.xs` ｜ **版本** 1.2.1（versionCode 1002001）｜ **平台** HarmonyOS / OpenHarmony，API 12+，编译 SDK 26

---

## 一、它解决什么问题

三方应用跑在自己的沙箱 uid 下，**没有办法**自己以 `shell` 身份执行系统命令。
StarPivot 通过两条路径拿到 `uid=2000(shell)` 的执行能力，再把能力统一成 HTTP + 界面：

1. **本机直连 hdcd（推荐，无需电脑）**：App 内直接与设备上的 `hdcd` 握手（RSA-3072/PSS 签名认证，
   密钥由 App 自行生成并保存在本应用 preferences），握手成功后拿到 shell 通道。
2. **PC broker（可选）**：电脑上跑 `pc-broker/broker.js`，用 `hdc rport` 把设备侧回环端口反向映射到电脑，
   App 通过回环访问 broker，由 broker 调 `hdc shell`。适合 hdcd 直连不可用的机型。

两条路径在 `Gateway` 里统一抽象，界面与 API 调用方无感切换。

> 无论哪条路径，执行身份都是 **uid=2000(shell)**，**不是 root**。读不到 `/data/app`、改不了系统分区。

---

## 二、能力一览

界面底栏四项：**概览 / 功能 / 接口 / 关于**。「功能」页左侧侧栏切换七个子页：

| 子页 | 能力 |
|---|---|
| 屏幕 | 截屏（可指定宽高）、点击、滑动、按键、文本输入、UI dump、保存到相册（走 SaveButton 临时授权） |
| 进程 | 进程列表、详情、强停 |
| 文件 | 目录浏览、读取、写入、删除 |
| 应用 | 应用列表/详情、启动、强停、安装、卸载、清缓存、共享库、quickfix 状态 |
| 解锁 | 亮屏 → 上滑 → PIN 输入（PIN 只存本机，不接受外部传入） |
| 诊断 | DFX 固定只读用例、崩溃列表/详情、沙箱隔离对照探测 |
| 终端 | 任意 shell 命令，自带 cwd 维持、历史 50 条、输出上限 200 KB、单条 30 秒超时 |

**本地 HTTP 网关**：默认 `127.0.0.1:18790`，除 `/v1/ping` 外全部要求请求头 `X-StarPivot-Token`。
令牌首次启动随机生成并持久化，可在「接口」页查看/复制。

主要端点（完整列表见 App「接口」页）：

```
/v1/ping                 /v1/capabilities        /v1/device
/v1/shell *              /v1/screen/capture      /v1/screen/tap|swipe|key|text
/v1/ui/dump              /v1/process/list|kill|detail
/v1/file/list|read|write|remove
/v1/app/list|detail|start|stop|install|uninstall|clean|shared|patch
/v1/log/events|hilog|crash|crashDetail
/v1/device/params|storage|top|udid|memory|cpu|cpufreq|cluster
/v1/net/sockets|iface|traffic|http
```

`*` `/v1/shell` **默认关闭**，需在「接口」页的「高危端点」开关里显式打开；打开后每次调用都会写审计日志。

---

## 三、构建与运行

> **第一次接触鸿蒙 / 没装过 DevEco？** 先看 [`docs/快速开始.md`](docs/快速开始.md)，
> 里面是从「下载 DevEco」到「截图成功」的 8 步手把手流程；本节的步骤假设你已经装好环境。

### 环境

- DevEco Studio（自带 SDK、Node、hvigor、JBR）
- 一台 API 12+ 的 HarmonyOS 设备，或模拟器

### 构建

```powershell
# DevEco 安装路径不在默认位置时先指定
$env:DEVECO_HOME = "D:\Program Files\Huawei\DevEco Studio"

.\build.ps1            # debug
.\build.ps1 -Release   # release（剥调试符号，体积约降 40%）
```

产物：`entry\build\default\outputs\default\entry-default-unsigned.hap`

也可以用 DevEco Studio 直接打开工程、登录华为账号做自动签名后 Run。

### 安装

```powershell
hdc install -r <已签名的 hap>
```

未签名的 HAP 不能装机。签名方式二选一：

1. DevEco Studio 的自动签名（需登录华为账号，会写入 `build-profile.json5` 的 `signingConfigs`）；
2. 你的调试证书 + profile（设备 UDID 需在 profile 的 `debug-info.device-ids` 里）。

### PC broker（可选）

```powershell
cd pc-broker
node broker.js          # 监听 127.0.0.1:18791
.\cli.ps1 status        # 查看状态；详细用法见 cli.ps1 头部注释
```

电脑侧需要 `hdc` 在 PATH 中，且设备已 `hdc list targets` 可见。

---

## 四、目录结构

```
.
├─ AppScope/                 应用级配置与图标
├─ entry/                    主模块（ArkTS / Stage 模型）
│  └─ src/main/ets/
│     ├─ common/ApiServer.ets    本地 HTTP 网关（含令牌校验、体积上限、审计）
│     ├─ common/Gateway.ets      能力封装，PC / 本机两条通道统一
│     ├─ common/LocalHdc.ets     免电脑直连 hdcd 的协议实现
│     ├─ common/Broker.ets       PC broker 客户端
│     ├─ pages/Index.ets         全部界面
│     └─ entryability/           入口 Ability
├─ hvigor/                   构建工具配置
├─ pc-broker/                电脑侧 broker（Node.js）
├─ release/                  1.2.1 发行产物（HAP + 发行说明）
├─ docs/                     零基础文档（快速开始 / 名词解释 / FAQ / 接口调用 / 更新说明）
├─ build.ps1                 构建脚本（-Release 出发行包）
├─ XS-UI-设计规格文档.md      配色、字号、间距规范
├─ README.md / CHANGELOG.md / SECURITY.md / LICENSE
```

---

## 五、权限

`module.json5` 只声明一条：

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` | HTTP 网关、socket 回环、broker 通信 |

以下是**刻意没有**声明的：

- `WRITE_IMAGEVIDEO`：保存截图走安全控件 `SaveButton` 的临时授权，不需要受限权限；
- `GET_NETWORK_INFO`：工程内没有 `connection.*` 调用，声明了属于清单不诚实，已移除；
- `READ_PASTEBOARD`：剪切板只写不读。

---

## 六、安全边界与使用范围

- 本工具的全部能力都限制在 **uid=2000(shell)** 的 DAC 权限内，**不具备** root、绕过签名校验、
  修改系统分区、跨应用读私有目录的能力；相关路径实测返回 `EACCES` / `ENOENT`。
- 本地网关只监听 `127.0.0.1`，靠令牌鉴权；**仍视为高敏感服务**——任何拿到令牌的本机应用都能调用。
  请勿在不受信任的设备上长期开启，用完关掉。`/v1/shell` 默认关闭。
- 「解锁」页的 PIN 存在本应用的 preferences 里，只用于本机自动化，不通过任何接口对外提供。
- 请仅在自己的设备上使用。用于他人设备前请取得明确授权，并遵守当地法律与平台条款。

---

## 七、已知限制

1. 工程不内置签名材料，HAP 需自行签名。
2. 应用图标为占位图（首字色块）。
3. 终端没有 PTY，不支持 `vi`、`top` 这类交互式/持续刷新程序；输出为整段返回，非流式。
4. `targetSdkVersion` 未显式配置（沿用 compatible 值），构建会有一条 hvigor 提示。
5. 接口文档以 `docs/接口调用.md` 与 `ApiServer.ets` 为准；接口页的内联说明为速查版。
6. 仅在 MatePad 11.5 S（SLG-W50，OpenHarmony 7.0.0.111，API 26）上实测；其它机型未验证。

---

## 八、文档索引

| 文档 | 什么时候看 |
|---|---|
| [`docs/快速开始.md`](docs/快速开始.md) | 第一次跑这个项目，从装 DevEco 开始 |
| [`docs/名词解释.md`](docs/名词解释.md) | 不懂 HDC / hdcd / uid=2000 / HAP / profile 是什么意思 |
| [`docs/常见问题.md`](docs/常见问题.md) | 装不上、连不上、401、`Permission denied`、签名报错 |
| [`docs/接口调用.md`](docs/接口调用.md) | 要在自己的应用或脚本里调它的接口 |
| [`docs/更新说明-相对1.2.0.md`](docs/更新说明-相对1.2.0.md) | 想知道 1.2.1 相对上一版改了什么 |
| [`XS-UI-设计规格文档.md`](XS-UI-设计规格文档.md) | 要改界面配色 / 字号 / 间距 |

---

## 九、许可

MIT，见 [LICENSE](LICENSE)。

第三方组件：仅使用 HarmonyOS 系统 Kit（ArkUI / NetworkKit / CoreFileKit / ArkData / CryptoArchitectureKit 等），
无外部 npm / ohpm 运行时依赖。`pc-broker` 仅使用 Node.js 内置模块。

---

*作者：天狼星蚀（GitHub: [XiotenStellar67](https://github.com/XiotenStellar67)）*
