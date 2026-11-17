# v110 — 双引擎：播放搬到真实网页（登录与全部功能不动）

## 为什么
决定性对照（2026-11-17 13:14，她实测）：同一台手机、同一网络、同一账号，
Safari 打开网页版**秒播**；App 内嵌的 loadHTMLString「假页面」引擎却逐首
恶化（5s → 20s → 中止 → 81s）。元凶是内嵌容器本身，不是队列管理，也不是
线路。v108–109.2 修好的队列层（串行 op、同队列跳转、坏 id 剔除、中止不
升级重装）全部保留，包进新引擎页继续用。

## 架构
- **登录引擎（原打包页）**：一行未改。继续负责大陆账号授权、令牌、
  在线更新（引擎 109.2）、API 数据层的令牌供给、设置页账号状态。
- **播放引擎（新）**：第二个 WKWebView，加载真实网页
  `https://taratara19172008-cmyk.github.io/aoi-music/player-engine.html`
  （GitHub Pages，与 Safari 秒播的网页版同源同环境）。页面本体 =
  109.2 播放核心 + 令牌注入口 `AoiEngine.setUserToken(t)`：
  App 把登录引擎拿到的 musicUserToken 递给它，MusicKit configure 后
  直接赋值 `music.musicUserToken`，实例即已授权，**不弹登录窗**
  （此注入路线有公开实战先例）。ENGINE_VERSION 独立编号 110.0。
- **路由**：Player 的全部传输调用（playQueue/play/pause/next/prev/
  jumpTo/seek/setShuffle/setRepeat/电台）走 `transport` 选择器：
  播放引擎 ready 后走播放引擎；未 ready（启动瞬间/页面加载失败）时
  回落登录引擎——最差情况等于 v109，不会更糟。
- **回调**：两个引擎共用 Player 的状态/进度/当前曲目/错误处理器；
  播放引擎就绪后，登录引擎的空闲进度推送被门控忽略（防其 0 进度
  每 500ms 冲掉真实状态）。
- **令牌转发**：EngineBridge 新增 onAuth 观察（不改登录流程本身）：
  登录引擎每次 auth 状态变化，Player 立即把令牌转给播放引擎；
  playSongs 前还有一次补递（防启动竞态）。

## 没动的东西（按她要求）
界面全部、登录流程与打包引擎页 engine.html、收藏/喜爱逻辑与防抖、
AI（聊天/推荐/多 provider）、资料库、搜索、电台页、首页、设置页其他
部分、小组件代码、APIClient 数据层——全部原样。改动文件仅：
EngineBridge.swift（双模式+令牌转发）、Player.swift（传输路由）、
Views/RootView.swift（多挂一个全屏隐形 webview）、
Views/SettingsView.swift（诊断多一行播放引擎状态）。

## 自测
- 播放引擎页 harness 52/52：109.2 全套（跳转/剔除/中止/计时）+
  令牌注入 4 项（就绪前暂存→初始化时生效、auth 回报携带令牌、
  就绪后立即生效、空令牌清除）。
- Swift 四文件括号平衡检查通过；Player 内无残留的直连传输调用
  （收藏的账号守卫仍指向登录引擎，正确）。

## 装后验证（设置页诊断应看到）
- 「播放引擎: v110.0 · ready · 已授权」+ 其日志含
  `user token applied`；随后播专辑连切数首应接近 Safari 的速度。
- 若显示「未就绪」：说明 Pages 页面没加载成功，传输已自动回落
  登录引擎（= v109 行为），把诊断截图发回即可定位。
- 之后播放引擎的修复走 Pages 推送（改 player-engine.html 推
  aoi-music 仓库即可），不用再出安装包；登录引擎仍走原在线更新。
