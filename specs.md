# MissionControlEnhance 规格说明

## 0. 背景与目标

macOS 的调度中心（Mission Control）只有在开启「按应用程序将窗口分组」时才会显示应用图标，但分组后就看不清同一应用的多个窗口，体验和 Cmd+Tab 差不多。不分组时又没有图标，只能靠缩小后的窗口内容辨认应用，内容颜色不明显时很难分辨。

本软件是一个原生 macOS 菜单栏应用，在**不分组**的调度中心之上叠加一层：

1. 在每个窗口缩略图左上角显示所属应用的图标；
2. 鼠标悬停时显示**关闭窗口 / 最小化窗口 / 退出应用**按钮；
3. 支持**鼠标中键点击**或**触控板三指按下（物理点按）**缩略图，快速关闭对应窗口。

---

## 1. 技术可行性

### 1.1 核心问题与方案

| 问题 | 方案 | 依赖 |
|---|---|---|
| ① 何时显示 / 隐藏 | **完全展开**：`AXExposeShowAllWindows` / `AXExposeShowFrontWindows` 通知（在缩放动画结束时到达）。**开始关闭**：调度中心打开期间以 120Hz 轮询 Dock 的子元素数量，`mc` 组消失即隐藏；`AXExposeExit` 要等退出动画结束才到，只作兜底 | 辅助功能权限 |
| ② 每个缩略图在屏幕上的位置 | 调度中心由 Dock.app 绘制。打开时 Dock 的 AX 树中出现 `mc` → `mc.display` → `mc.windows` 层级，每个窗口缩略图是一个带 `AXFrame` / `AXTitle` 的元素 | 辅助功能权限 |
| ③ 缩略图属于哪个应用、哪个窗口 | 预先维护窗口清单（各应用 AX 窗口的标题、`CGWindowID`，以及 `CGWindowList` 中的 pid / bounds），按标题和宽高比把缩略图匹配到具体窗口 | 辅助功能权限（不需要屏幕录制权限） |
| ④ 在调度中心之上绘制图标 / 按钮 | 每块屏幕一个无边框透明 `NSPanel`，`collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`，窗口层级高于调度中心 | 无 |
| ⑤ 点击按钮、中键点击时调度中心不退出 | 用 `CGEventTap` 在会话层拦截鼠标事件：命中按钮或缩略图时**吞掉事件**，Dock 收不到，调度中心保持打开 | 辅助功能权限 |
| ⑥ 关闭 / 最小化窗口、退出应用 | 关闭：对目标窗口的 `kAXCloseButtonAttribute` 执行 `AXPress`；最小化：设置 `kAXMinimizedAttribute = true`；退出：`NSRunningApplication.terminate()` | 辅助功能权限 |
| ⑦ 识别三指按下 | 三指按下触控板产生的是普通左键事件；用私有框架 `MultitouchSupport.framework` 实时跟踪触控板上的手指数，左键按下时若手指数为 3 即判定为三指按下（MiddleClick 使用同一方案） | 可能需要输入监控权限（待阶段 0 确认） |

> **最大的不确定点在 ②。** Dock 的 AX 树具体长什么样，是否带应用 / 窗口 ID，在不同 macOS 版本上可能不同。当前开发环境是 macOS 26，必须先做阶段 0 验证再写正式代码。Mission Control Plus 等第三方工具已在调度中心叠加关闭按钮，可以作为可行性旁证。

### 1.2 技术选型

- **语言 / UI**：Swift 6。叠加层用 AppKit + Core Animation（`CALayer` 绘制图标和按钮）；设置界面用 SwiftUI。
- **系统 API**：
  - `ApplicationServices`：AX API、`CGEventTap`
  - `CoreGraphics`：`CGWindowListCopyWindowInfo`、显示器信息
  - `AppKit`：`NSWorkspace`、`NSRunningApplication`（图标、退出）
  - `ServiceManagement`：`SMAppService`（开机自启）
- **私有 API**：
  - `_AXUIElementGetWindow`：从 AX 窗口拿到 `CGWindowID`，提升匹配准确度（可选）
  - `MultitouchSupport.framework`：三指按下识别（可选功能，失效时自动降级）
- **分发**：不能进 App Store（沙盒禁止读取其他进程的 AX、禁止事件拦截）。使用 Developer ID 签名 + 公证，Sparkle 自动更新（可选）。
- **形态**：只在菜单栏显示（`LSUIElement = YES`），不出现在 Dock 和 Cmd+Tab 中。
- **最低系统**：macOS 13。
- **权限**：
  - 辅助功能（必需）
  - 输入监控（仅在开启三指按下时按需申请，视阶段 0 结果而定）
  - 不申请屏幕录制权限（macOS 15+ 会周期性反复询问）；窗口标题从各应用 AX 获取。

---

## 2. 运行时数据流

```
            ┌──────────────────────┐
            │  WindowInventory      │ ← 后台持续维护：应用启动/退出、窗口创建/关闭/改名
            │  (pid, bundleID,      │   (NSWorkspace 通知 + 每个应用的 AXObserver)
            │   AXUIElement,        │
            │   title, CGWindowID,  │
            │   frame, aspect)      │
            └─────────▲────────────┘
                      │ 查询
Dock AX 通知 ──► MissionControlMonitor ──► DockAXScanner ──► WindowMatcher ──► OverlayRenderer
 (Expose/Exit)     (状态机: idle/        (遍历 mc 子树,      (缩略图 → 窗口)    (每屏一个 NSPanel,
                    entering/active/      得到 [Thumbnail])        │             图标 + 悬停按钮)
                    exiting)                                       │
                         │                                         ▼
                         │                               ThumbnailRegistry（当前帧的
                         │                               缩略图 frame ↔ 窗口 映射）
                         │                                         ▲
                         │                                         │ 命中测试
                         ├──── 进入时启用 / 退出时停用 ────► InputInterceptor
                         │                                 (CGEventTap: 移动/左键/中键;
                         │                                  MultitouchSupport: 手指数)
                         │                                         │
                         │                                         ▼
                         │                                   WindowActions
                         │                               (关闭 / 最小化 / 退出应用)
                         │                                         │
                         └──────────── 操作完成后触发重新扫描 ◄──────┘
```

### 2.1 关键细节

- **不跟随缩放动画**：只在调度中心完全展开后显示，开始关闭的瞬间隐藏。Dock 的 AX 树不提供动画过程中的位置，跟随只能靠预测曲线，复杂且容易出现偏差。
  - 显示：收到 `AXExposeShowAllWindows` 后扫描、匹配、渲染，然后在 0.1 秒内淡入。实测在窗口停稳后 1 到 3 帧开始出现。
  - 隐藏：120Hz 轮询发现 `mc` 组消失时，立即清空。实测在窗口开始移动的那一帧就已经隐藏。
  - 预判隐藏：凡是会移动或关闭调度中心内容的输入，都立即隐藏，不等 Dock。如果之后调度中心仍然开着，就**重新扫描**缩略图（切换桌面后缩略图会变）再显示。具体包括：
    - 点击（缩略图以外的区域也算）、Esc、回车、⌃↑：0.3 秒后检查。
    - ⌃← / ⌃→ 切换桌面：0.45 秒后检查。
    - 触控板三指 / 四指滑动：滑动期间窗口跟随手指移动，但 Dock 的 `mc` 组要等手势结束才会消失。这类手势以私有的 CGS “dock control” 事件（类型 30，字段 110 = 23 DockSwipe，字段 132 为阶段：1 开始、4 结束、8 取消）经过会话层事件流，事件拦截在“开始”时隐藏，在“结束 / 取消”后 0.35 秒检查（覆盖松手后的回弹）。
  - 隐藏期间，按钮、中键和三指按下都不响应，防止点到看不见的按钮。
  - 空闲时不做任何轮询。
- **窗口清单预热**：`WindowInventoryCache` 为每个应用注册 AXObserver（窗口创建、移动、缩放、改名、销毁等），去抖 150ms 后刷新该应用的窗口。调度中心展开时直接用缓存匹配，同时在后台全量刷新一次以纠正缓存。
- **位置跟踪**：active 状态下前 1 秒每 100ms、之后每 500ms 扫描一次 Dock AX，处理缩略图 frame 的修正、切换桌面等情况。
- **清晰度**：
  - 图标和按钮按 `pt × backingScaleFactor` 的实际像素栅格化（`ImageRasterizer`），并设置图层的 `contentsScale`。直接把 NSImage 交给 CALayer 会在 Retina 屏上按 1x 渲染后再放大，导致模糊。
  - 所有图层的坐标和尺寸都对齐到物理像素（`OverlayPanel.local`）。图标外伸 `0.3 × 36 = 10.8pt`，即 21.6px，不是整数像素；位图放在非整数像素位置时，合成器会对整张图重新插值，肉眼可见地发虚，这是之前图标模糊的主要原因。
- **坐标转换**：AX 坐标原点在主屏左上角，AppKit 原点在左下角，多显示器时按各屏 frame 分别换算。
- **性能**：AX 调用是同步的跨进程通信，放在专用串行队列中执行，用 `AXUIElementSetMessagingTimeout` 设置超时。
- **健壮性**：监听 `com.apple.dock` 重启（`killall Dock`、系统更新），重新注册观察者。
- **事件拦截安全**：
  - `CGEventTap` 只在调度中心 active 时启用，退出后立即停用，平时对系统零影响；
  - 回调中只做命中测试（纯内存操作），实际窗口操作异步派发，避免回调超时；
  - 处理 `kCGEventTapDisabledByTimeout` / `ByUserInput`，自动重新启用；
  - 未命中任何按钮 / 缩略图的事件一律原样放行。

### 2.2 窗口匹配算法（WindowMatcher）

**主路径：按窗口服务器的 bounds 精确匹配。** 调度中心打开期间，`CGWindowListCopyWindowInfo` 报告的窗口 bounds 就等于该窗口缩略图的 frame。读取 bounds、所属进程和窗口 ID 不需要屏幕录制权限（只有窗口名需要）。

1. 缩略图 frame 与某个窗口的 bounds 相同（容差 1pt），且只有这一个窗口 → 得到它的窗口 ID 和所属进程。
2. 按窗口 ID（AX 窗口通过 `_AXUIElementGetWindow` 取得）找到对应的 AX 窗口 → 精确匹配（`.window`）。如果缓存里还没有这个 AX 窗口，则只确定了应用（`.app`），下一次扫描会补上。

实测 14 个缩略图全部精确命中。之所以不再以标题为主，是因为 AX 标题可能和调度中心显示的不一致：Edge 等 Chromium 浏览器会在 AX 标题后面附加 ` - Microsoft Edge`（以及个人资料名），按标题匹配会失败。如果没有屏幕录制权限，连按窗口名兜底也做不到，图标就不会显示。

**兜底：按标题 + 宽高比匹配**，只用于 bounds 没有命中的缩略图：
1. 只有一个窗口的标题和缩略图标题相同 → 直接匹配。
2. 多个窗口同名 → 比较宽高比，再参考相对位置，用贪心算法做全局分配。
3. 标题为空 → 在尚未匹配的窗口里只按宽高比匹配。
4. 置信度低于阈值 → 不显示图标，**也不显示操作按钮、不响应中键 / 三指按下**。显示错的图标只会误导，关错窗口则会造成损失。

---

## 3. 窗口操作

### 3.1 悬停按钮

- 鼠标进入某个缩略图时，在其右上角（可配置）淡入一组按钮：**关闭窗口 ×**、**最小化 −**、**退出应用 ⏻**。默认右上角，避开左上角的应用图标。
- 按钮只是 `CALayer` 绘制的图形，叠加层窗口本身仍然 `ignoresMouseEvents = true`。点击由 `InputInterceptor` 通过命中测试识别并吞掉，这样不需要叠加层获得焦点，调度中心不会因此退出。
- 悬停状态由 event tap 中的 `mouseMoved` 事件驱动（只读取，不拦截）。

### 3.2 操作实现

| 操作 | 实现 | 说明 |
|---|---|---|
| 关闭窗口 | 目标窗口 `kAXCloseButtonAttribute` → `AXPress` | 窗口没有关闭按钮时，不显示该按钮 |
| 最小化窗口 | `AXUIElementSetAttributeValue(kAXMinimizedAttribute, true)` | 不支持最小化的窗口不显示该按钮 |
| 退出应用 | `NSRunningApplication.terminate()` | 破坏性较大，默认需要二次确认：第一次点击按钮变红并显示“再次点击退出”，2 秒内再次点击才执行 |
| 强制退出 | 按住 Option 时，退出按钮变为强制退出：`forceTerminate()` | 同样需要二次确认 |

### 3.3 边界情况

- **有未保存内容的窗口**：关闭时应用会弹出保存确认，此时缩略图不会消失。叠加层在该缩略图上提示“需要处理保存对话框”，用户退出调度中心后处理。
- **操作后的重新排布**：操作完成后立即重新扫描 Dock AX，刷新图标和按钮位置。
- **操作失败**（AX 返回错误、应用无响应）：缩略图上短暂显示失败提示，不重试。

---

## 4. 快捷关闭：中键点击 / 三指按下

### 4.1 鼠标中键点击 —— 可行性：高

- `CGEventTap` 监听 `kCGEventOtherMouseDown` / `kCGEventOtherMouseUp`，`kCGMouseEventButtonNumber == 2`。
- 命中某个缩略图（且匹配置信度足够）时吞掉事件，在 mouseUp 时执行操作（与按钮的点击语义一致，按下后移出缩略图可取消）。
- 未命中时原样放行。
- 依赖的辅助功能权限已经有了，无需额外权限。
- 默认动作为关闭窗口，可配置为：关闭窗口 / 最小化 / 退出应用 / 无。

### 4.2 触控板三指按下（物理点按）—— 可行性：中高（依赖私有框架）

**系统行为**：在触控板上用三根手指按下时，系统产生的是**普通的左键按下 / 抬起事件**（`kCGEventLeftMouseDown` / `Up`）。双指按下会被转换为右键，三指不会被特殊处理。事件本身不携带手指数，公开 API 无法区分单指按下和三指按下，所以需要额外拿到“按下那一刻触控板上有几根手指”。

**方案**：“手指数跟踪 + 左键拦截”，即 MiddleClick 的做法。

1. `MultitouchBridge` 通过 `MultitouchSupport.framework`（`MTDeviceCreateList`、`MTRegisterContactFrameCallback`、`MTDeviceStart`）注册回调，持续记录每个触控板**当前接触的手指数**和最近一帧的时间戳。只在调度中心 active 时启动监听，退出时停止。
2. `InputInterceptor` 收到 `leftMouseDown` 时：
   - 最近一帧（≤ 100ms 内）的手指数 == 3，并且光标命中某个高置信度缩略图 → **吞掉该事件**，记录待执行状态（目标窗口）；
   - 否则原样放行。单指点击照常进入窗口，不受影响。
3. 待执行状态下，同一次点击的 `leftMouseDragged`、压力事件（Force Touch 的 `pressure` / 用力点按）一并吞掉。
4. 收到对应的 `leftMouseUp` 时也吞掉；若光标仍在同一缩略图上，执行配置的动作（默认关闭窗口），移出则取消。语义与按钮、中键一致。

**备选方案（阶段 0 一并验证）**：触控板手势事件（`NSEvent.EventType.gesture`）中带有触点集合，若 event tap 能稳定收到这类事件，就可以用公开但未文档化的方式拿到手指数，不依赖私有框架。

**与系统手势的冲突**：

| 系统手势 | 是否冲突 | 说明 |
|---|---|---|
| 三指上滑 / 下滑、三指左右滑 | 否 | 这些是滑动，不产生左键按下 |
| 三指拖移（辅助功能） | 否 | 三指拖移不需要按下；若用户按下，依然以“左键按下时手指数”判定 |
| 用力点按（查询） | 否 | 整个点击序列的压力事件都已被吞掉 |
| 双指按下（右键） | 否 | 系统产生的是右键事件，不经过此逻辑 |
| 手指刚落下 / 刚抬起时恰好按下 | 边缘情况 | 手指数在 2 / 3 之间抖动时按最近一帧判定，误差只会导致“这次没触发”，不会误关单指点击的窗口 |

**风险**：

- 私有框架可能随系统更新失效。框架加载失败或回调不工作时，自动禁用该功能（左键行为完全不变），并在设置中显示“当前系统不支持”。
- 读取原始触摸数据可能需要输入监控权限，在阶段 0 中确认。
- 有多个触控板（内置 + 妙控板）时，按“最近一帧有触点”的设备判定。

### 4.3 防误关

- 只对高置信度匹配的缩略图生效（见 2.2）。
- 可选“撤销”：关闭后 2 秒内在原位置显示“已关闭 ·（应用名）”提示。窗口一旦关闭就无法恢复，所以这里只做提示，不承诺撤销。
- 设置中可单独开关中键 / 三指按下功能。三指按下需要额外权限且依赖私有框架，**默认关闭**，在设置中开启时引导授权。

---

## 5. 软件功能架构

```
MissionControlEnhance.app
├── 核心功能
│   ├── 调度中心中，在每个窗口缩略图左上角显示所属应用图标
│   ├── 悬停显示 关闭窗口 / 最小化 / 退出应用 按钮
│   ├── 鼠标中键点击缩略图 → 执行配置的动作（默认：关闭窗口）
│   ├── 触控板三指按下缩略图 → 执行配置的动作（默认关闭此功能）
│   └── 支持多显示器、全屏应用空间
├── 外观设置
│   ├── 图标大小（24–64pt）、位置（四角 / 居中偏上）
│   ├── 图标样式：阴影、半透明底座、圆角
│   ├── 可选：图标旁显示应用名
│   └── 按钮组位置、按钮大小、显示哪些按钮
├── 行为设置
│   ├── 排除特定应用（不显示图标 / 按钮，不响应快捷关闭）
│   ├── 仅一个应用有多个窗口时才显示图标（可选）
│   ├── 出现动画：淡入 / 跟随 / 无
│   ├── 中键动作：关闭窗口 / 最小化 / 退出应用 / 无
│   ├── 三指按下动作：同上
│   └── 退出应用前二次确认（默认开启）
├── 应用外壳
│   ├── 菜单栏图标（启用 / 暂停、设置、退出）
│   ├── 首次启动引导：申请辅助功能（及按需的输入监控）权限，并检测授权状态
│   └── 开机自启
└── 诊断
    ├── 调试模式：给每个缩略图画框，显示匹配结果、置信度、命中区域
    ├── 三指按下调试：实时显示各触控板当前手指数、最近一次左键按下时的判定结果
    └── 导出 Dock AX 树（适配新系统版本、提交 bug 时使用）
```

### 5.1 工程目录

```
MissionControlEnhance/
├── App/          AppDelegate, MenuBarController, Onboarding
├── Core/         MissionControlMonitor, DockAXScanner, WindowInventory,
│                 WindowMatcher, ThumbnailRegistry
├── Input/        InputInterceptor (CGEventTap), FingerCountTracker
├── Actions/      WindowActions, ConfirmationState
├── Overlay/      OverlayPanel, OverlayRenderer, IconLayer, ButtonBarLayer
├── Settings/     Preferences (UserDefaults), SettingsView (SwiftUI)
└── Support/      AXHelpers, CoordinateSpace, Permissions,
                  DockLayoutAdapter（按系统版本适配 Dock AX 结构）,
                  MultitouchBridge（私有框架的动态加载与符号绑定）
```

- `DockLayoutAdapter` 单独隔离：每次 macOS 大版本更新，Dock 的 AX 结构都可能变，升级时只需改这一层。
- `MultitouchBridge` 用 `dlopen` / `dlsym` 动态加载，框架缺失时不会导致应用崩溃。

---

## 6. 开发路线

| 阶段 | 内容 | 产出 |
|---|---|---|
| **0. 验证（关键）** | ① 导出 Dock AX 树：确认 macOS 26 上缩略图元素结构、frame 精度、是否带应用 / 窗口信息；② 验证叠加层窗口层级能否盖住调度中心；③ 验证 event tap 吞掉左键 / 中键后调度中心是否保持打开；④ 验证 MultitouchSupport 在 macOS 26 上是否可用、是否需要输入监控权限，以及三指按下时 event tap 收到的确实是左键事件；⑤ 验证手势事件中能否拿到触点（备选方案） | 可行性结论 |
| 1. 最小可用版本 | Monitor + Scanner + 按标题匹配 + 单屏图标叠加 | 能在左上角看到图标 |
| 2. 准确性 | WindowInventory 缓存、同名窗口消歧、多显示器 | 日常可用 |
| 3. 窗口操作 | InputInterceptor、悬停按钮、关闭 / 最小化 / 退出、二次确认、中键关闭 | 能在调度中心直接管理窗口 |
| 4. 三指按下 | MultitouchBridge、FingerCountTracker、左键拦截逻辑、调试面板 | 可选功能 |
| 5. 体验 | 设置界面、动画、排除列表、开机自启、权限引导 | 完整产品 |
| 6. 发布 | 签名、公证、Sparkle 自动更新 | 可分发 |

---

## 7. 风险与备选方案

- **Dock AX 树中没有缩略图信息或 frame 不准**：可以退回到截图 + 图像匹配（需屏幕录制权限，开销大，不推荐）。更务实的备选是自己实现类似调度中心的窗口总览（类似 AltTab 网格模式），图标、分组、按钮完全可控，代价是不用系统自带的调度中心。
- **系统更新导致失效**：依靠 `DockLayoutAdapter`、`MultitouchBridge` 隔离，加上诊断导出，把适配成本降到最低。
- **叠加层层级不够、被调度中心盖住**：阶段 0 验证，从 `.screenSaver` 级别开始往上试。
- **event tap 吞掉点击后调度中心仍然有反应**（例如 Dock 也在更底层监听）：阶段 0 验证。若无法阻止，按钮改为放在独立的 non-activating `NSPanel` 上接收点击，并验证此方式不会导致调度中心退出。
- **误关窗口**：低置信度不响应、退出应用二次确认、三指按下默认关闭。
- **台前调度（Stage Manager）**：最小可用版本不支持，后续单独处理。

---

## 8. 阶段 0 验证结论（macOS 26.7，2026-10-31）

| 验证项 | 结论 |
|---|---|
| Dock AX 树 | `AXApplication(Dock) > AXGroup#mc > AXGroup#mc.display(AXDisplayID) > AXGroup#mc.windows > AXButton`。每个按钮只有 `AXTitle`（窗口标题，可能为空）和 `AXFrame`，**没有应用或窗口 ID**，必须靠匹配 |
| 缩略图 frame | 打开后约 20ms 即为最终布局；偶尔会先报告窗口原始 frame，所以前 1 秒每 100ms 轮询一次 |
| 进入 / 退出时机 | `AXExposeShowAllWindows` 在 `mc` 组出现后约 257ms 到达，此时缩放动画刚结束，正适合显示。`AXExposeExit` 在 `mc` 组消失后约 255ms 才到达，此时退出动画已经结束，太晚；`mc` 组在退出动画开始的同一帧内消失。（多次录屏逐帧测得。注意测量探针本身不能阻塞主线程，否则 AX 回调和绘制都会被推迟，得出错误结论） |
| 叠加层层级 | `CGWindowLevelForKey(.screenSaverWindow)`（1000）能盖住调度中心；面板需要**常驻**（调度中心打开前就已在屏幕上），且自身不会成为缩略图 |
| 拦截点击 | session event tap 吞掉 mouseDown / mouseUp 后，调度中心保持打开 |
| 中键 | Dock 本身不响应中键，无冲突 |
| AX 关闭 / 最小化 | 能生效，窗口从画面上消失（调度中心留下空位，不重新排布），但 **Dock 的 AX 树不会更新**，被关闭的缩略图仍在列表中。由 `WindowActions` 验证结果，协调器自己记录已关闭的缩略图 |
| 元素身份 | 同一缩略图的多次 AX 查询结果 `CFEqual` 相等，可以作为跨扫描的键 |
| 窗口服务器 bounds | 调度中心打开期间，每个窗口的 `kCGWindowBounds` 等于其缩略图的 frame，可以按 bounds 精确找到窗口 ID 和所属进程（无需屏幕录制权限） |
| MultitouchSupport | `dlopen` 与全部符号可用，能枚举到内置触控板；物理三指按下待在真机上用设置页里的手指数探针确认 |

## 9. 构建与运行

只需要 Command Line Tools，不需要 Xcode：

```bash
./scripts/build.sh                 # 生成并签名 build/MissionControlEnhance.app
open build/MissionControlEnhance.app  # 首次运行会请求辅助功能权限
```

- 脚本会自动选用钥匙串里的 `Developer ID Application` / `Apple Development` 证书签名，签名身份稳定，重新编译后不需要重新授权。可以用 `SIGN_IDENTITY="-"` 改为 ad-hoc 签名。
- Command Line Tools 不带 SwiftUI 宏插件，所以设置界面不用 `@State`，视图状态放在 `ObservableObject` 里。
- 菜单栏「调试模式」会给每个缩略图画框：绿色表示精确匹配到窗口，黄色表示只确定了应用，红色表示未匹配；同时显示匹配代价。
