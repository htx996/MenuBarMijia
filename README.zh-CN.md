[English](README.md) | 简体中文

<p align="center">
  <a href="https://trendshift.io/repositories/309141?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-309141" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/309141/daily?language=Swift" alt="jryang1997%2FMenuBarMijia | Trendshift" width="250" height="55"/></a>
  <a href="https://trendshift.io/repositories/309141?utm_source=trendshift-badge&amp;utm_medium=badge&amp;utm_campaign=badge-trendshift-309141" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/trendshift/repositories/309141/weekly?language=Swift" alt="jryang1997%2FMenuBarMijia | Trendshift" width="250" height="55"/></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="docs/assets/logo-light.svg">
    <img src="docs/assets/logo.svg" width="120" alt="MenuBarMijia Logo">
  </picture>
</p>

<h1 align="center">MenuBarMijia</h1>

> [!IMPORTANT]
> **非小米官方产品，与小米无关联。** MenuBarMijia 是独立开源项目，并非小米或米家官方客户端，与小米科技有限责任公司及其关联公司不存在隶属、合作、赞助或背书关系。「小米」「米家」「Xiaomi」「Mijia」「Mi Home」是小米科技有限责任公司及其关联公司的商标。本项目仅在说明与小米 / 米家设备的兼容性时使用这些名称，不暗示任何背书或认可。

<p align="center">
  <b>在电脑上，顺手控制整个家。</b><br>
  面向 macOS 的原生菜单栏智能家居控制工具，亦提供 Windows 11 托盘版本。<br>
  无需提前搭建 Home Assistant，手机扫码即可连接米家；支持键盘拼音盲搜、按住说话、状态联动与误触撤销。
</p>

<p align="center">
  <a href="https://github.com/jryang1997/MenuBarMijia/stargazers"><img src="https://img.shields.io/github/stars/jryang1997/MenuBarMijia?style=social" alt="GitHub Stars"></a>
  <a href="https://github.com/jryang1997/MenuBarMijia/releases/latest"><img src="https://img.shields.io/github/v/release/jryang1997/MenuBarMijia?color=0A84FF&label=release" alt="Latest Release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Windows_11-Tauri_v2-0078D4?logo=windows11&logoColor=white" alt="Windows 11">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License">
</p>

<p align="center">
  <a href="https://jryang1997.github.io/menubarmijia-web/">项目官网</a> ·
  <a href="https://github.com/jryang1997/MenuBarMijia/releases/latest">下载最新版本</a> ·
  <a href="#快速开始">安装与连接</a> ·
  <a href="#功能概览与双端对照">平台能力对照</a> ·
  <a href="#安全隐私与限制">安全与限制</a> ·
  <a href="#star-history">Star 曲线</a> ·
  <a href="CHANGELOG.md">更新日志</a>
</p>

```bash
# macOS 用户推荐通过 Homebrew 一行安装
brew install --cask jryang1997/tap/menubarmijia
```

---

<p align="center">
  <img src="docs/assets/readme-v2/hero-keyboard.gif" alt="macOS 演示模式：使用快捷键、拼音搜索书房台灯并开启" width="900">
</p>

<sub>macOS 离线演示模式，设备与数据均为虚拟内容。</sub>

---

## 为什么把家居控制放进电脑

在电脑前工作或开会时，不必特意拿起手机打断手头的事：

1. **手不离键盘，打字找灯：** 按下 `⌥M` 呼出面板，输入名字或拼音首字母（如 `sftd` 找「书房台灯」），回车直接开关，展开详情后用左右方向键调节亮度或空调温度。不用切换中文输入法，不用在多层房间列表里滚动寻找。
2. **按住说话，松手执行：** 长按全局快捷键 `⌥M` 或菜单栏图标开始说话，说完松开立即执行。常规开关、调光、调温由本地规则解析；多步或模糊指令可由你自选的 AI 处理，没有唤醒词，也不做多余的语音播报。
3. **跟上你的工作状态：** 人离开 Mac 锁屏时自动关掉书房灯，接上外接显示器时打开桌面氛围灯。这些联动由你自己设置，想怎么用就怎么用。
4. **一键全关，也能一键撤销：** 睡前按住「全关」，给灯和其他设备一起放个假。插座与扫地机默认不参与；如果关错了，点一下底部的「撤销」就能恢复。

---

## 操作演示

下面用 macOS 演示模式，带你看看几个常用操作。

### 1. 按住说话，松手执行

无需唤醒词。长按全局快捷键或菜单栏图标直接说话，执行完成后在输入框旁显示耗时与执行方式回执（本地规则解析或云端模型决策）。

<p align="center">
  <img src="docs/assets/readme-v2/voice-ptt.gif" alt="macOS 演示模式：按住快捷键说话并将书房台灯切换到月光模式" width="900">
</p>

### 2. 批量全关与即刻撤销

出门或睡前，按住「全关」0.6 秒，就能关掉当前视图中参与全关的设备。插座、扫地机和摄像机默认留着，你也可以在设置里调整；不小心关错了，点「撤销」就好。

<p align="center">
  <img src="docs/assets/readme-v2/undo-all-off.gif" alt="macOS 演示模式：长按全关、保留插座并撤销恢复" width="900">
</p>

### 3. 跟随 Mac 屏幕状态联动

将日常离开或回到工位的动作转化为自动化。锁屏、合盖休眠时自动关闭指定房间照明；解锁唤醒或连接外接显示器时触发指定环境。此外还可按摄像头 / 麦克风占用、接通电源与电量阈值、Wi-Fi 名称、专注模式开关、日历会议开始前和深夜使用逐条联动；这些 Mac 专属触发默认关闭，Wi-Fi 名称、专注状态与日历需要系统权限，授权后才会触发。

<p align="center">
  <img src="docs/assets/readme-v2/automation-away.gif" alt="macOS 自动化演示：锁屏后客厅吸顶灯关闭" width="900">
</p>

### 4. 温湿度趋势与插座用电统计

今天屋里是不是比昨天热了一点？在 macOS 上点开温湿度计，就能看看过去 24 小时或 7 天的变化。支持电量读数的插座还能查看今日用电，最近 7 天的记录在设置里。

<p align="center">
  <img src="docs/assets/readme-v2/sensor-chart.gif" alt="macOS 演示模式：查看温湿度的 24 小时和 7 天趋势" width="900">
</p>

---

## 功能概览与双端对照

MenuBarMijia 的 macOS 版本采用 Swift 6 原生开发，Windows 11 版本基于 Tauri v2 / TypeScript 独立实现。两端均经过共享测试集（`Tests/Fixtures/`）断言基础协议的一致性，但系统级能力存在平台差异。

| 功能维度 | macOS 原生版 (14+) | Windows 11 托盘版 | 说明 |
| :--- | :---: | :---: | :--- |
| **米家云端扫码直连** | ✅ 支持 | ✅ 支持 | 手机米家 App 扫码登录，支持中/欧/美/俄/新加坡多区域服务器；同时加载自有家庭与被分享给该账号的家庭 |
| **Home Assistant 接入** | ✅ 支持 | ✅ 支持 | 双端支持局域网原生 WebSocket 直连与官方 `xiaomi_home` 物理设备聚合 |
| **键盘搜索与设备控制** | ✅ 支持 | — 暂不支持 | macOS 支持拼音首字母（如 `sftd`）与设备名搜索，以及方向键控制 |
| **全局快捷键呼出** | ✅ `⌥M`（支持自定义） | ✅ `Alt+M`（支持自定义） | 1.1.4 Windows 版已补齐自定义热键录制与占用冲突检测 |
| **语音控制方式** | ✅ 菜单栏按住 / 快捷键按住 / 免提 | ⚠️ 仅免提听写 | macOS 支持系统原生听写与按住说话；Windows 使用 WebView 听写 |
| **本地口令解析** | ✅ 支持 | ✅ 支持 | 开关、调光、调温、风速、延时等常规口令双端均在本地解析 |
| **自选 AI 决策助手** | ✅ 支持 | ✅ 支持 | 可选接入 Jev、DeepSeek、Ollama 等；默认「不确定时先问我」，具体阈值在高级设置里 |
| **「猜你想控」主动推荐** | ✅ 最多 4 项 | ✅ 最多 4 项 | 手动点卡片也按时段与工作日/周末计入习惯记忆，带 14 天半衰期衰减与动作序列预测（撤销同步回滚，详见 [ADR-0009](docs/adr/0009-habit-ranking-algorithm.md)）；本地推荐立即显示，大模型在后台刷新。可执行动作不足四项时显示实际数量。 |
| **GrokBall 情绪球与侧边推荐** | ✅ 原生 Canvas | ✅ 内置 SVG 引擎 | 轻点小球展开最多四项可撤销设备推荐，再点或按 Esc 收起；macOS 默认黑球白眼，可自由拖动，长按 0.5 秒进入语音输入，胶囊随球相对面板的位置向外展开，并根据屏幕空间调整行列。Windows 保留固定侧挂。眼睛跟随光标，减弱动态效果下静态显示。基于 [TyCoding/grok-ball](https://github.com/TyCoding/grok-ball)（MIT）。 |
| **顶部快捷动作与场景栏** | ✅ 3 个动作 | ✅ 4 个动作 | 通过设置里的「显示顶部快捷场景栏」开关。macOS 提供 全屋关灯 / 柔和夜灯 / 关温控风扇，Windows 提供 全开主灯 / 睡眠关灯 / 25°制冷 / 调亮灯光；接入 Home Assistant 后双端都会追加你的场景胶囊。macOS 下动作与场景合计不超过四项时等宽铺满，更多则支持普通鼠标滚轮横向滚动。 |
| **批量全关与即刻撤销** | ✅ 支持 | ✅ 支持 | 长按 0.6 秒触发；插座与扫地机默认不参与，可调整；操作可撤销时提供 10–15 秒横幅 |
| **Mac 状态自动化** | ✅ 支持 | — 暂不支持 | 支持锁屏、唤醒、外接显示器，以及摄像头 / 麦克风占用、电源与电量、Wi-Fi、专注模式、日历与深夜使用等 Mac 专属触发（默认关闭） |
| **系统快捷指令集成** | ✅ 支持 (4 个动作) | — 暂不支持 | 提供设备切换、执行场景、一句话控制、查询温湿度 4 项 App Intents |
| **URL Scheme 控制** | ✅ 支持 | — 暂不支持 | `menumijia://toggle` 等调用默认需确认，可在设置中允许直接执行 |
| **传感器历史折线图** | ✅ 24h / 7d 趋势 | ⚠️ 基础读数显示 | macOS 可切换温度或湿度及时间范围，Windows 显示基础读数 |
| **插座电量统计** | ✅ 支持 | — 暂不支持历史统计 | macOS 仅统计插座上报的真实累计电量增量，无数据不凭空估算 |
| **米家空净 / 新风机 / 加湿器** | ✅ 支持 | ✅ 支持 | 双端合成 `air-purifier`、`air-fresh`、`humidifier` 规格：PM2.5 / 空气质量 / 温湿度 / 滤芯余量，风速 1–100% 联动最爱挡位 |
| **冰箱与厨房家电** | ✅ 支持 | ✅ 支持 | 冰箱按冷藏、冷冻分室显示当前与目标温度，支持 手动 / 智能 / 假日 / 速冷 / 速冻 模式；电水壶、饮水机、电饭煲、空气炸锅、烤箱、微波炉、养生壶显示工作状态、温度与剩余分钟数，带 `start-cook` / `pause` 动作的机型可直接启停 |
| **除湿机 / 水暖毯 / 香氛机 / 音箱** | ✅ 支持 | ✅ 支持 | 除湿机合成为风扇卡，按其上报的模式列表切换并读取自身温湿度，水暖毯合成为温控卡，香氛机作为可开关插座，音箱作为媒体卡支持音量、静音、播放状态、睡眠模式与文本播报 |
| **门锁与人体、环境传感器** | ✅ 只读卡片 | ✅ 只读卡片 | 门锁显示电量。读到 `door-state` 或 Home Assistant 的 `lock` 实体时展示已上锁、已开锁、虚掩或卡住；没有可靠状态时显示「锁状态未知」，不再固定写成「守护中」。人体移动/存在、门窗磁、水浸、光照与空气质量监测合成为传感器卡片；MIoT 不开放远程开锁，门锁只作状态展示。米家网关、路由器、中继器按网络基础设施过滤，不再混进未知设备列表 |
| **摄像机实时画面** | ✅ 支持 | ✅ 支持 | 点击卡片放大弹出置顶实时小窗：macOS 走 HLS / HA 抓拍流，Windows 内置私有 P2P 桥（安装包内置组件，可选流畅 / 高清 / 超清） |
| **布局编辑调大小** | ✅ 支持 | ✅ 支持 | 编辑模式下卡片右下角显示 iOS 控制中心风格圆弧手柄：向外/向内拖拽逐档切换 半行 ↔ 整行 ↔ 展开面板，轻点则循环切换 |
| **界面外观** | ✅ 一套系统外观 + 4 档高度 | ✅ 控制中心风格 | macOS 只用系统材质：开启的设备取当前外观下最亮的表面——浅色是亮色磁贴，深色是比关闭态高一级的玻璃——其余是安静玻璃。 |
| **安装签名与更新机制** | ⚠️ 本地签名 + Ed25519 验签更新 | ⚠️ 未签名安装包 | macOS 需手动允许首次打开；Windows 首次安装有 SmartScreen 提示 |

---

## 快速开始

### 1. 系统要求与安装

- **macOS：** 支持 macOS 14 (Sonoma) 及以上系统（Universal Binary 通用二进制，原生支持 Apple Silicon 与 Intel 芯片）。
- **Windows：** 支持 Windows 11（64 位）。

#### macOS 安装方式

**方式 A：通过 Homebrew 一行安装（推荐）**
```bash
brew install --cask jryang1997/tap/menubarmijia
```
> 若 Homebrew 提示需要信任第三方 Tap，可先执行 `brew trust --cask jryang1997/tap/menubarmijia`。

**方式 B：下载 DMG 手动安装**
前往 [GitHub Releases](https://github.com/jryang1997/MenuBarMijia/releases/latest) 下载最新的 macOS DMG 安装包，打开并将 `MenuBarMijia.app` 拖入「应用程序（Applications）」文件夹。
> **首次打开拦截说明：**<br>
> 本项目为个人开源作品，尚未加入付费的 Apple 开发者计划（未完成 Developer ID 公证）。首次启动若被 Gatekeeper 拦截，请打开 **「系统设置 → 隐私与安全性」**，在页面底部点击针对 MenuBarMijia 的 **「仍要打开」** 即可。

#### Windows 11 安装方式

前往 [GitHub Releases](https://github.com/jryang1997/MenuBarMijia/releases/latest) 下载最新的 Windows x64 `.exe` 或 `.msi` 安装包。
> **SmartScreen 提示说明：**<br>
> 当前 Windows 正式发布包暂未购买商业代码签名证书。首次安装若弹出“Windows 已保护你的电脑”，请点击 **「更多信息」→「仍要运行」**。安装包 SHA-256 哈希值已在 Releases 页面公开，可自行校验完整性。

---

### 2. 连接你的智能设备

启动应用后，点击常驻图标展开控制面板，点击右下角设置齿轮 `⚙️`：



- **方式一：米家云端扫码直连（推荐）：**<br>
  在设置中选择「米家云端直连」，屏幕上将显示登录二维码。使用手机「米家」App 扫码并确认登录，全屋家庭、房间与设备将自动同步到面板中。macOS 支持在设置中继续点击「添加账号」同时登录多个不同地区或家人的小米账号，自动合并全部账号的设备与家庭（Windows 端暂为单账号登录）。当小米登录响应声明了 `serviceToken` 到期时间或服务端返回登录失效时，面板会在到期前 3 天提前提示，并在已过期时将菜单栏图标切换为断连态（`house.slash`），支持在面板内一键弹出二维码重新扫码续期（未声明有效期的凭据不凭空猜测寿命）。
- **方式二：接入已有 Home Assistant：**<br>
  选择「Home Assistant」，填写实例根地址（如 `http://192.168.1.100:8123`）与长期访问令牌。Windows 保存设置后需在原生对话框允许该来源，令牌保存在 Windows 凭据管理器。拒绝授权或连接失败不会切换到演示模式。Windows 支持现有灯、温控、风扇、插座、冰箱、扫地机、摄像机控制和传感器卡片，以及场景和脚本。macOS 独有设备类型与 HA 摄像机实时流不在本次 Windows 后端范围内。<br>
  macOS 上连接局域网地址或 `.local` 主机时，可能被系统的本地网络隐私开关拦截。面板会直接提示「局域网连接被系统拦截」，而不是一句笼统的套接字错误。请在 **「系统设置 → 隐私与安全性 → 本地网络」** 中允许 MenuBarMijia；若仍然失败，重新安装一次以对齐本地应用签名。
- **方式三：离线演示模式（Demo Home）：**<br>
  无需账号即可使用虚拟设备体验界面和控制操作。

---

## 常用操作与口令参考

### 键盘快捷操作

以下面板内操作适用于 macOS，Windows 的默认呼出快捷键为 `Alt+M`。

| 按键 | 功能 |
| :--- | :--- |
| `⌥M` | 全局呼出 / 收起控制面板 |
| 直接输入字母 | 搜索设备名称、房间或拼音首字母（如 `sftd` 匹配书房台灯） |
| `↑` / `↓` | 在搜索结果或设备卡片列表中切换光标 |
| `Return` / `Space` | 开关当前选中的设备；对不可直接开关的设备展开详情控制抽屉 |
| `→` / `←` | 右方向键展开详情；展开后用左右方向键调节灯光亮度、空调温度或音量 |
| `Tab` | 在不同房间标签之间快速轮转切换 |
| `Esc` | 退出搜索输入、收起控制抽屉，或关闭面板 |

### 本地支持的常用自然语言口令

以下口令由本机规则引擎直接解析执行，**不需要配置云端 AI**，不消耗 API Token：

- **开关设备：** 「关客厅灯」「打开书房空调」「turn off all lights」
- **调节情景模式：** 「书房吸顶灯月光模式」「日光模式」「daylight mode」
- **微调亮度与色温：** 「再暗一点」「主卧灯调到 40%」「brighter」
- **温度与风速控制：** 「空调调到 26 度」「调高两度」「风扇开自然风」
- **延时定时执行：** 「10 分钟后关灯」「半小时后关空调」「取消定时」
- **撤销误操作：** 「撤销」「刚才那个撤销」（10 分钟内支持语音或快捷撤销）

---

## 安全、隐私与限制

MenuBarMijia 是独立开源项目，并非小米官方客户端。米家云直连需要联网；已有 Home Assistant 时，可在 macOS 或 Windows 上连接自己的实例。

### 凭据存放在哪

| 凭据 | 保存的内容 | 位置 |
| :--- | :--- | :--- |
| 米家 / Xiaomi Home | 每个已登录账号的 `userId`、`cUserId`、`ssecurity`、`serviceToken`、云端地区与声明的到期时间 | macOS 钥匙串（一条通用密码项）或 Windows 凭据管理器 |
| Home Assistant | 长期访问令牌（实例地址不属于机密） | macOS 钥匙串或 Windows 凭据管理器 |
| AI 助手 | 各服务商已保存的 API 密钥、导入来源标记与已允许的云端授权地址 | API 密钥在 macOS 钥匙串 / Windows 凭据管理器；非机密的标记在应用偏好中 |
| LG webOS 电视 | 电视签发的配对客户端密钥 | macOS 钥匙串 |

macOS 会将这些钥匙串项加密保存，并由登录钥匙串保护；MenuBarMijia 写入时使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，首次解锁后可用，但不会同步到 iCloud 或另一台 Mac。应用不会把这些机密写进明文 `UserDefaults` 或日志。macOS 更新后可能询问一次钥匙串授权（构建签名发生变化）；选择「始终允许」即可覆盖之后的读写。

1.0.6 及更早版本曾把凭据镜像到明文 `UserDefaults`。升级后首次启动时，每个旧明文值都会先写入钥匙串，写入成功后才删除对应明文键。钥匙串不可用时，旧副本会保留以便下次重试，而不是假装迁移已经成功。

### 高风险控制、锁屏与吊销

高风险设备的手动操作也需要二次确认，而不只是 AI 建议的操作：打开电暖器、切换插座或摄像机、启动扫地机，或打开热水器 / 调高热水器温度。关闭这些设备的操作保持直接执行，避免「想让家里更安全却先被弹窗拦住」。门窗与燃气报警在本应用中只是只读状态卡片，无法在这里被操作。确认规则与 AI 策略共用同一张表，位于 `Sources/MijiaCore/ModelActionPolicy.swift`。

设置 → 「隐私」中有 **「锁屏时禁止控制设备」**，默认开启。Mac 锁屏期间，卡片与详情控制、`menumijia://` 链接、快捷指令 / App Intent 与助手命令都会被拒绝并提示；定时任务与 Mac 事件自动化规则仍然执行。开关保存在本机，锁屏状态来自系统的锁屏通知。

同一设置页提供 **「退出并吊销令牌」**，需要先经过破坏性确认。它会退出全部米家账号、删除 Home Assistant 令牌并断开连接，同时清除已保存的 AI 密钥与云端授权记录；设备名称、房间布局与本地历史保留。也可以逐项吊销：米家账号区的「退出登录」、把 HA 令牌替换为空值，或 AI 设置中每个密钥旁的「撤销」。

常用指令由本地规则处理。你也可以接入自己选择的 AI 服务，处理更复杂的说法；发送给服务的内容包括指令、设备及环境信息，以及你启用的习惯摘要。手动点卡片操作也会在本机学习时段习惯（只用于「猜你想控」推荐）；学习开关可随时关闭，已学内容可在设置中查看并一键清空，点击撤销横幅会同步回滚对应习惯记录。语音识别使用系统服务，支持的语言可开启「语音只在本机识别」。

为了避免误操作，AI 不确定时会先问你（设置里的「不确定时先问我」，默认开启）；开启电暖器、切换插座或启动扫地机等高风险操作即使很有把握也会先问。URL 控制默认也会先确认，可以在设置中开启直控。

macOS 安装包尚未经过 Apple 公证，首次打开时可能需要在系统设置中允许；Windows 安装包可能触发 SmartScreen。macOS 应用内更新使用 Ed25519 公钥校验签名，私钥离线保管。更多连接方式说明见 [ADR-0007](docs/adr/0007-lan-direct-deferred.md)。

私下报告漏洞的步骤写在英文的 [Security policy](SECURITY.md)。

---

## 参与开发与技术架构

- **架构理念：** macOS 端为纯 Swift 6 开发，**运行时代码无第三方 Swift 依赖**，开启严格并发检查；核心协议解析与状态合成抽象为独立模块 `MijiaCore`（可脱离 UI 单独运行全量单元测试）。Windows 端基于 Tauri v2 (Rust + TypeScript + Vite) 构建独立托盘程序。
- **跨平台一致性保证：** 双端使用 `Tests/Fixtures/` 目录下的共享 Golden 语料（意图、规格书、区域、服务商测试数据）进行各自断言，确保解析规则不分叉（详见 [ADR-0006](docs/adr/0006-dual-platform-implementation.md)）。

### 本地构建与验证

```bash
# macOS 本地全量测试与代码门禁检查
bash scripts/check.sh

# 编译、打包并启动 macOS 本地构建
bash scripts/build_app.sh

# Windows 托盘版本地构建与测试
cd windows
npm install
npm test
npm run build
```

在提交 Pull Request 前，请先阅读 [CODING_STANDARDS.md](CODING_STANDARDS.md) 了解代码规范；项目领域概念见 [GLOSSARY.md](GLOSSARY.md)。

---

## 贡献者与致谢

感谢为 MenuBarMijia 提交代码、修补协议细节与打磨交互体验的贡献者：

- [@jryang1997](https://github.com/jryang1997)（一群小羊说）— 项目发起与维护
- [@almightyYantao](https://github.com/almightyYantao)（Alimighty.Yantao）— 多键 Mesh 开关分键设备识别与合成（[#6](https://github.com/jryang1997/MenuBarMijia/issues/6)、[#7](https://github.com/jryang1997/MenuBarMijia/pull/7)）、米家多家庭切换与灯组情景过滤（[#8](https://github.com/jryang1997/MenuBarMijia/pull/8)）、多主题面板皮肤、空调/温湿度计独立模块、长按拖拽自由布局与自定义分组（[#9](https://github.com/jryang1997/MenuBarMijia/pull/9)）、macOS 应用图标打包集成（[#10](https://github.com/jryang1997/MenuBarMijia/pull/10)）、面板下落动画、本地设备重命名与房间栏细节打磨（[#11](https://github.com/jryang1997/MenuBarMijia/pull/11)）、Windows 功能对齐与跨端界面修复（[#12](https://github.com/jryang1997/MenuBarMijia/pull/12)），以及连接源快照的冗余写入优化（[#66](https://github.com/jryang1997/MenuBarMijia/pull/66)）

## 协议与致谢

- **开源协议：** 本项目采用 [MIT License](LICENSE) 开源。
- **第三方集成说明：** 本仓库不分发任何第三方官方组件。涉及 Home Assistant 模式下的 [xiaomi_home](https://github.com/XiaoMi/ha_xiaomi_home) 与 [midea_ac_lan](https://github.com/wuwentao/midea_ac_lan) 分别来自小米及其各自维护者，版权归各自作者所有。
- **商标声明：** 「小米」「米家」「Xiaomi」「Mijia」等为小米科技有限责任公司注册商标；「美的」为美的集团股份有限公司注册商标。本文档与本项目仅用于描述设备兼容性。

感谢所有为 MenuBarMijia 提交代码、报告缺陷与改进建议的贡献者！如果这个小工具让你在工作时少掏了几次手机，欢迎在 GitHub 上点一个 ⭐ Star。

---

## Star History

每一个 Star 都是一次「少掏手机」。下方曲线由 [star-history.com](https://star-history.com/#jryang1997/MenuBarMijia&Date) 生成。

<p align="center">
  <a href="https://star-history.com/#jryang1997/MenuBarMijia&amp;Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=jryang1997/MenuBarMijia&amp;type=Date&amp;theme=dark">
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=jryang1997/MenuBarMijia&amp;type=Date">
      <img src="https://api.star-history.com/svg?repos=jryang1997/MenuBarMijia&amp;type=Date" alt="jryang1997/MenuBarMijia 的 Star 增长曲线" width="720">
    </picture>
  </a>
</p>
