# CHANGES v119 — 搜索框根级修法 + DOM 弹窗猎手

背景：v118 真机验收三项未过——搜索框仍跳（第三种死法）、「The operation was aborted.」弹窗仍出现、The Fate of Ophelia 仍 30 秒且无动态封面。她发来两段录屏逐帧取证，并让问 GPT（第 6 轮，同对话三条 Think 消息）。

## 证据（录屏逐帧）
- 弹窗：出现后不拦截触摸（她直接点中背后的搜索框、光标出现）、App 列表内容绘在它上层、OK 点不到、跨页面挂几分钟 ⇒ 不是 UIAlertController、不是 window.alert，而是引擎 WKWebView 内部的 DOM 弹层（引擎页全屏垫底 + allowsHitTesting(false)，显示得出却永远点不掉；三层 JS-alert 拦截全沉默与此吻合）。GPT 独立得出同一结论。
- 搜索框：键盘过渡中覆盖层 VStack 拿到的布局矩形不稳定——升起时变宽（leading 98 消失）、顶部被状态栏切；收起后有一帧落到屏幕最底部。迷你播放器随键盘上浮；左栏稳态基本不动。三轮布局内 shield（v115 页内、v116 根级条件、v118 覆盖层）全败，共同点是键盘安全区一直在根布局里参与重排。

## 本轮改动（2 个文件）
1. **RootView.swift — 根级关闭键盘安全区**：新增 `KeyboardRegionFixer`（UIViewRepresentable），搜索页激活时把窗口根视图控制器及其子控制器的 `safeAreaRegions` 设为 `.container`（键盘整体排除出 SwiftUI 根布局，刘海/状态栏/Home Indicator 不变），离开搜索页恢复 `.all`（AI 聊天输入框仍需键盘避让）；切换记日志（`root keyboard safe area OFF/ON`）。同时：搜索框脱离全高 VStack，改为根 ZStack 直接子层、整帧 topLeading 显式钉位；删除 v116 的条件 `.ignoresSafeArea(.keyboard)` shield。
   - 代价（已知会）：搜索页打字时键盘会盖住迷你播放器（与主流 app 一致），不再顶起界面。
2. **EngineBridge.swift — DOM 弹窗猎手**：新增 `dialogHunterSource` WKUserScript（document start、全框架、page 世界）：MutationObserver 监控每帧 DOM，精确匹配文案 `the operation was aborted`，向上定位弹窗容器（语义 dialog 元素，或含 OK 按钮且文本 <300 字的短元素），先经 `aoi` handler 上报（Swift 侧用 `frameInfo` 记 main frame / subframe host + 标签 + 文本，日志行 `dom dialog removed [...]`），再 close + remove。v118 的 JS 对话框桩抽为静态源码，与猎手一起在授权弹窗（createWebViewWith）里补注。

## 本轮不改（等证据）
- The Fate of Ophelia 试听与动态封面：她那次会话引擎仍是 109.17（109.18 待重开生效），且无该曲 `animated artwork` 日志行；等 109.18 生效后的日志再定点。
- 点歌后约 3 秒出声空窗（视频 2）：setQueue 落定延迟，先观察 109.18 表现。
- 0:02 疑似自暂停：未定性，需日志。

## 首包失败与修正（build #25 → 本定版）
- build #25 编译失败：`safeAreaRegions` 不在 `UIViewController` 上（GPT 引的文档实为 `UIHostingController` 专有属性），RootView 三处报错。已按 GPT 答复 2 的原案改为应用自持根控制器：
- **AoiMusicApp.swift 重写**：SwiftUI `WindowGroup` 入口改为 UIKit 场景生命周期——`@main AppDelegate` + `SceneDelegate` 自建窗口、持有对象图（settings/api/engine/player/nav/shazam，原 @StateObject 群），根控制器为自有子类 `AoiHostingController: UIHostingController<AnyView>`（静态弱引用 + `setKeyboardExcluded` 设置后回读 regions 记日志）。`KeyboardRegionFixer` 改为只调用该静态方法，不再遍历窗口。Info.plist 的 SceneManifest 补上 `UISceneConfigurations`（SceneDelegate 类名 + AppDelegate 内程式指定双保险）。深链 `aoimusic://shazam` 改由 SceneDelegate 的 openURLContexts 处理（含冷启动 connectionOptions）。

## 自检
- 两个注入 JS 均经 node --check 通过；改动文件括号平衡；safeAreaRegions 为 iOS 17 的 UIHostingController 属性，部署目标 17.0 全 target 一致，无需 #available 守卫；自定义类型名 KeyboardRegionFixer / AoiHostingController 无系统成员冲突。Info.plist 经 plistlib 解析通过。
