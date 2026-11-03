# MenuBarMijia

macOS 菜单栏智能家居控制中心，将群晖 Home Assistant 或米家云端直连接入的设备合成为符合 Apple Control Center 交互范式的桌面面板。

## Language

### 核心领域实体

**SmartDevice（逻辑设备）**：
面板中展示与操控的最小设备单元（如一台空调、一盏吸顶灯、一台双开门冰箱），由同一物理设备下的多个 Home Assistant 原始实体或 MIoT 服务属性聚合而成。
_Avoid_: Entity（原始实体）、Widget（小组件）、Accessory（配件）

**RawEntity（原始实体）**：
底层数据源暴露的单点状态或动作寻址接口（如 Home Assistant 的 `light.*`、`sensor.*_temperature` 或米家云端的 `miot:<did>:<siid>`），仅存在于数据同步与命令下发边界，不直接暴露给用户界面。
_Avoid_: Device（设备）、Card（卡片）

**DeviceSynthesis（设备合成）**：
将 Home Assistant 注册表/状态表或米家云端设备列表/MIoT 属性值，按物理归属与功能优先级折叠为 `SmartDevice` 列表与 `EnvironmentReading` 的纯函数转换过程。
_Avoid_: Data mapping（数据映射）、Parsing（解析）

**HomeBackend（连接后端）**：
驱动 `HomeStore` 的底层数据源配置，支持局域网 `Home Assistant`（`HAWebSocketProvider`）与免网关的 `米家云端直连`（`MiCloudProvider`）；当 macOS 客户端同时配置并登录两端时自动并行连接并合并设备，仅配置一端时单源运行，演示模式由 `DemoHomeProvider` 提供。Windows 采用互斥数据源选择，HA 通过原生 `ha_snapshot`、`ha_execute` 与 `HomeAssistantClient` 接入，不进行双源合并。
_Avoid_: Server type（服务器类型）、Mode（模式）

**DeviceDeduplication（跨源设备去重合并）**：
当 Home Assistant 与米家云端同时生效时，按硬件标识（`xiaomi_home` 的 `<server>_<did>`、裸 `did`、MAC 地址）及同房间唯一同款/同名规则识别同一台物理设备，并按「在线状态优先 → 可控能力评分优先 → 同分 Home Assistant 优先」选出单一胜出数据源驱动该 `SmartDevice` 卡片的纯函数合并过程。
_Avoid_: Cloud sync（云同步）、Entity bridge（实体桥接）

**MiSession（米家云端会话）**：
通过小米账号二维码扫码登录获取并持久化在钥匙串中的会话凭证（含 `userId`、`ssecurity`、`serviceToken` 与区域），用于签名与加解密 `/app/*` 请求。这里的 RC4 是小米云 `api.io.mi.com` 私有接口的**传输层**加密（`MIOT-ENCRYPT-ALGORITHM: ENCRYPT-RC4`），不是端到端加密：指令与状态经小米服务器中转，服务器可读明文。
_Avoid_: Token（令牌）、Cookie（网页凭据）、End-to-end encryption（端到端加密）

**MiAccount（米家账号）**：
一个已登录的小米账号在某个云端区域下的凭据集合，身份由区域与 `userId` 派生，同一账号在同一区域重复扫码只刷新凭据。一个安装可同时保存多个 `MiAccount`，各自使用独立区域与云端主机；设备按所属账号合并展示，面板在账号多于一个时将全屋视图下未归入常用或自定义分组的设备按账号分组。
_Avoid_: Session（会话）、Profile（账号配置）、Home（家庭）

**MiotSpec（MIoT 设备规格）**：
由 `miot-spec.org` 定义的设备型号能力描述模型（含服务 `siid`、属性 `piid`、动作 `aiid`、取值范围与枚举列表），作为米家云端设备合成与指令映射的元数据契约并按型号缓存于本地。
_Avoid_: Schema（模式）、Profile（配置表）

**RoomArea（房间区域）**：
物理空间的归属划分（如客厅、书房、卧室、次卧、厨房），以 Home Assistant 的区域注册表或米家家庭房间列表为准并经过名称归一化。
_Avoid_: Zone（防区）、Group（分组）

**HomeOption（米家家庭）**：
小米账号下的独立家庭空间（由 `homeroom/gethome` 的 `homelist` 返回，含家庭 ID、名称与去重设备数），支持在面板顶部切换查看单个家庭或合并查看全部家庭。
_Avoid_: Workspace（工作区）、Account（账号）

**SplitDevice（多键分键设备）**：
多键 Mesh 墙壁开关等复合设备由 `v2/home/device_list_page` 拆分出的独立按键记录（`did` 形如 `<parentDid>.s2`，携带 `splitParentDid` 与 `splitSiid`）；合成时隐藏父面板并以各分键作为独立 `SmartDevice` 展示，MIoT 读写仍寻址父 `did` 与对应 `siid`。
_Avoid_: Sub-entity（子实体）、Virtual plug（虚拟插座）

**EnvironmentReading（环境读数）**：
从在线温湿度计、带内置温湿度的空气净化器/风扇以及带当前室温读数的空调/电暖器提取，按「独立传感器 → 空气净化器 → 空调室温」优先级排序并展示在面板顶部与菜单栏的实时温湿度指标。
_Avoid_: Weather（天气）、Telemetry（遥测）

### 控制与偏好

**Scene（场景）**：
在 Home Assistant（或由米家同步至 HA）中定义的一键多设备联动动作（`scene.*` / `script.*`），在菜单栏面板中仅触发执行，不在本地维护编排逻辑。
_Avoid_: Automation（后台自动化规则）、Macro（宏）

**QuickAction（内置快捷动作）**：
基于设备类别自动聚合的批量领域指令（如「全屋关灯」「柔和夜灯」「睡眠关温控」），无需在 Home Assistant 预置场景即可一键执行。执行后按设备数给出撤销横幅：1–2 台 10 秒、3 台及以上 15 秒（`HomeStore.undoBannerSeconds(forDeviceCount:)`，指针悬停时暂停）；横幅消失后，助手的最后一次动作仍可用「撤销上一步」在 10 分钟内回滚。
_Avoid_: Local scene（本地场景）、Custom script（自定义脚本）

**AllOffTarget（全关目标）**：
「全关」实际会关闭的设备集合（`HomeStore.allOffTargets`）：当前视图内、开启中、且能从面板关闭的设备。默认不参与全关的类别（插座、扫地机、摄像机，`joinsAllOffByDefault` 返回 false）可由用户按设备覆盖（`setJoinsAllOff`），覆盖结果持久化。
_Avoid_: All devices（全部设备）

**DeviceListCut（房间或类型筛选）**：
当前家庭设备列表上的一次性筛选。同一时刻只能是全部设备、一个房间，或一种设备类型（灯、空调、插座等，各房间合在一屏）。不写入磁盘。选中类型时 `selectedRoomId` 仍为空，常用、分组、房间角标和磁贴尺寸继续按全部房间那一页计算。点「全部」、点某个房间，或切换家庭，会取消类型筛选。
_Avoid_: IntentDeviceCategory（意图设备大类）、Persistent filter（持久筛选）

**IntentPlan（意图执行计划）**：
自然语言指令经本地规则解析（`LocalIntentParser`）或远端大模型回退（`ModelIntentResolver`）后生成的结构化设备操作列表（`[DeviceIntent]`）与简短反馈文案，经能力校验后由 `HomeStore` 并发下发并支持多设备一键撤销。
_Avoid_: Prompt output（模型输出）、Action script（动作脚本）

**ScheduledCommand（定时指令）**：
带有绝对触发时刻 `fireDate` 与已解析 `IntentPlan` 的延时控制任务，持久化在本地 `UserDefaults`（`assistant_scheduled_commands_v1`）。应用重启时未到期项按剩余时间继续倒计时；退出期间已过期项转入 `missedScheduledCommands` 待确认队列并保留在磁盘，必须由用户点击「立即执行」或「忽略」后才执行或移除，绝不在后台静默触发过期硬件动作。
_Avoid_: Background job（后台任务）、Cron（计划任务）

**ActiveDevice（活跃开启设备）**：
当前在线且处于工作状态的受控设备（开着的灯、正在制冷/制热的空调或电暖器、运行中的风扇、通电开启的插座、清扫中的扫地机、播放中的音箱、监控中的摄像机）。顶部「全关」只作用于其中参与全关的 AllOffTarget；插座、扫地机、摄像机等常年通电或看护设备默认不计入全关目标（冰箱、待机电视、纯传感器整体不算活跃设备）。
_Avoid_: Online device（在线设备）

**CompactTile（双列紧凑磁贴）**：
每行并排展示两张设备的紧凑网格视图；当任意设备展开详情抽屉时，该卡片自动切换为跨满整行宽度以容纳滑块与模式按钮。
_Avoid_: Mini card（迷你卡片）、Widget（小组件）

**SafetyAlert（主动守护提醒）**：
macOS 原生通知。原有四类仍按原规则提醒：插座持续开启 45 分钟且**实时功率超过 300 W**（没有功率读数就不触发）、空调或电暖器连续运行 4 小时、传感器或门锁电量低于 15%、星标设备意外离线。低电量同一设备 24 小时内不重复，冷却时间持久化；带关闭动作的提醒可在通知上直接执行。传感器边沿提醒另计：漏水、烟雾、燃气默认开启，门窗与人体移动默认关闭，每一类都能单独开关。报警从无到有才通知一次，危险类第一次采样已是报警也会通知，正文带检测时刻；恢复平静不通知。漏水、烟雾、燃气报警期间菜单栏图标变红。门窗和移动可以限制为只在这台 Mac 锁屏、睡眠或切换用户期间提醒。Windows 没有这条传感器提醒。
_Avoid_: Alarm（警报）、Push notification（远程推送）

**ProactiveSuggestion（猜你想控推荐）**：
结合用户全渠道操作习惯记忆（`UserHabitMemory`，涵盖时段与工作日/周末频次、时间衰减与动作序列预测，见 ADR-0009）、当前环境温湿度与在线设备，立即给出最多四项当前可执行的候选动作（`AssistantSuggestion`）；配置大模型时在后台刷新。动作不足四项时显示实际数量。
_Avoid_: Static shortcut（静态快捷方式）、Random tip（随机提示）

**GrokBall（AI 情绪表情球）**：
控制面板外的球面双目动态组件，实时注视光标，并随睡眠、待机、聆听、思考、执行成功与异常状态切换表情；macOS 的默认、好奇和睡眠表情使用黑色球体与白色眼睛，支持自由拖动与长按 0.5 秒进入语音输入。轻点后最多展示四项设备 `ProactiveSuggestion`，macOS 根据球在主面板的左、右、上、下位置向外安排胶囊，并在屏幕边缘调整行列或换向；Windows 保留固定侧挂与纵向推荐。展开不改变主面板卡片布局，设备推荐支持撤销，场景可通过语音或文本指令执行。
_Avoid_: Static icon（静态图标）、Chatbot avatar（聊天头像）

**LightGroupFold（米家灯组折叠）**：
把米家云端 `group.*` 灯组与其成员单灯合成一张卡片的展示规则：`v2/groupv2/query_status` 返回的成员归属（`member_ship`，插件 SDK 写作 `membership`）随设备列表缓存到 `SynthesizedHome.lightGroupOwners`；面板只在灯组卡片本身可见时，从 `HomeStore.visibleDevices` 隐藏其成员灯，`filteredDevices` 仍保留完整集合，因此全关、场景、搜索与助手继续按每盏成员灯计算。偏好「灯组内的单灯不重复显示」(`hideGroupedLights`) 默认开启。
_Avoid_: DeviceGroup（本地自定义分组）、Room grouping（房间分组）

**ViewPreference（本地视图偏好）**：
仅作用于当前客户端的展示配置（包括星标常用置顶、自定义分组 `DeviceGroup`、长按拖拽排序、通过编辑态卡片右下角圆弧手柄拖拽或轻点调节的分页面卡片尺寸 `TileSize`、单设备固定数据源覆盖、隐藏特定设备、隐藏离线设备、面板高度 `PanelHeight`、Windows 面板位置 `PanelAnchor`（跟随任务栏或工作区四角，保存在 `%APPDATA%\MenuBarMijia\panel-placement.json` 以便拖动窗口后即时落盘）、菜单栏常驻指标选择），存储在本地且不回写远端数据源。
_Avoid_: Device config（设备配置）、Profile（档案）
