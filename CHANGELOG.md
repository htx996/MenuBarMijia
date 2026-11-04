## 未发布

### 修复与设备支持
- **Windows 摄像机组件与画质（[#200](https://github.com/jryang1997/MenuBarMijia/issues/200), [#97](https://github.com/jryang1997/MenuBarMijia/issues/97)）**：安装包内置 `go2rtc` 与最小 LGPL FFmpeg，首次打开摄像机不再依赖 GitHub 下载；兜底下载改为 3 次重试、120 秒超时，并在失败时给出手动放置路径。实时小窗新增「自动 / 流畅 / 高清 / 超清」画质选择（默认高清），与 macOS 对齐。

### 体验
- **米家灯组折叠为一张卡片（[#189](https://github.com/jryang1997/MenuBarMijia/issues/189)）**：设备列表刷新时通过 `v2/groupv2/query_status` 缓存每个 `group.*` 灯组的成员（同时接受 `member_ship` / `membership` 两种拼写），面板把成员单灯折叠进灯组卡片，不再重复列出；灯组卡片被隐藏、离线或筛选掉时成员灯照常显示。偏好设置新增「灯组内的单灯不重复显示」（默认开启）。全关、场景、搜索与助手仍按包含成员的完整设备集合计算，折叠只影响可见列表。
- **首次启动只教三件事，进阶功能默认收起（[#180](https://github.com/jryang1997/MenuBarMijia/issues/180)）**：新手引导改为「连接账号 → 按 ⌥M 搜一个设备 → 全关后撤销」三步，完成一步才打勾；AI 指令、GrokBall、摄像机、自动化与 URL 直控收进默认折叠的「进阶」，每行注明设置位置。连接成功后，剩余两课改为面板顶部的「上手清单」，搜索与全关撤销可以边操作边看说明；三步都试过或手动关闭后才消失。AI 的「把握度低于 80% 需确认」改为「不确定时先问我」开关（默认开启），具体阈值移到高级设置；建议胶囊的悬浮说明也改成「AI 不太确定，点一下才执行」。

- **macOS 菜单栏右键菜单（[#250](https://github.com/jryang1997/MenuBarMijia/pull/250)）**：右键点击菜单栏图标即可在实时连接与演示模式之间切换，并查看 Home Assistant / 米家云端直连是否纳入当前连接；同一菜单还提供设置、检查更新与退出。菜单展开期间的点击、长按语音与面板高亮互不干扰，关闭菜单后的第一次左键点击立即生效，按 Esc 或通过键盘关闭菜单也不会再触发异常。

### 自动化
- **更多 Mac 上下文触发（[#174](https://github.com/jryang1997/MenuBarMijia/issues/174)）**：自动化规则新增摄像头 / 麦克风开始与停止使用、接通 / 断开电源、电量低于阈值、Wi-Fi 连接 / 离开（可指定 SSID）、深夜使用电脑（以 Mac 唤醒且未锁屏为准）、专注模式开关与日历会议开始前触发。全部默认关闭，需在「自动化与外部控制」中逐条添加；沿用既有的确认、乐观更新、失败回滚与 5 分钟撤销横幅。深夜规则每晚最多执行一次；日历规则按事件去重并忽略全天 / 已拒绝的事件。摄像头 / 麦克风通过 CoreMediaIO / CoreAudio 的 `IsRunningSomewhere` 读取，无需额外权限；Wi-Fi 名称需要「定位」权限，专注状态需要「专注状态」权限，日历需要完整日历访问权限，未授权时对应规则保持静默。公开 API 只提供「是否处于专注」而不提供具体专注模式名称，因此专注触发是开关而非按模式区分；摄像头 / 麦克风检测也会看到本应用自己的录音 / 录像。

### 安全
- **更新签名密钥支持过渡公钥与轮换 / 吊销预案（[#164](https://github.com/jryang1997/MenuBarMijia/issues/164)）**：双端信任集扩展为“当前签名公钥 + 可选过渡公钥”，清单 `key_id` 必须指向实际验签的密钥；新增[轮换与吊销操作手册](docs/security/update-signing-key-rotation.md)，覆盖正常轮换的 provisioning / 切主 / 退役、回滚窗口、密钥泄露与丢失、用户手动补救与审计命令。`scripts/check.sh` 现在同时校验两端过渡公钥的一致性。

### 修复
- **Windows 面板跟随任务栏位置，并可拖动到指定角落（[#204](https://github.com/jryang1997/MenuBarMijia/issues/204)）**：面板位置改按显示器工作区（`GetMonitorInfoW` → `rcWork`，经 Tauri `Monitor::work_area`）而不是整块屏幕计算，任务栏在上、左或右时面板贴近任务栏那一侧，不再为不存在的底部任务栏固定预留 54 px 的空白；托盘左键与 Alt+M 共用同一套定位逻辑（托盘点击按图标所在显示器定位），面板高度变化时保持所贴的边不动。偏好设置新增「面板位置」（跟随任务栏 / 左上 / 右上 / 左下 / 右下），选择持久化到 `%APPDATA%\MenuBarMijia\panel-placement.json`；按住面板顶部空白处可拖动窗口，松手后吸附到最近的工作区角落并记住该位置。

### 测试
- **外部接口契约回放与确定性模糊测试（[#186](https://github.com/jryang1997/MenuBarMijia/issues/186)）**：`Tests/Fixtures/contracts/` 新增脱敏录制（米家设备列表页、共享家庭房间、属性批量读取、MIoT 实例与实例索引、HA WebSocket 消息序列），由 `ContractReplayTests` 逐字段断言应用依赖的稳定字段；`FragmentedMP4Demuxer`、MIoT 规格解析与 HA 消息解析新增固定种子、限定迭代次数的模糊测试。模糊测试同时修复了大数 / 非有限值在 `JSONValue.intValue`、`idString`、MIoT `value-list` 与 HA 传感器合成中的整数转换崩溃，以及 fragmented MP4 `tfhd` / `trun` 可选字段越界读取崩溃，均附回归用例。真实 libFuzzer 目标未接入：这些解析器是可直接调用的纯函数，带种子的进程内 fuzz 已能在普通 `swift test` 中跨平台复现崩溃，无需额外 LLVM 工具链。
