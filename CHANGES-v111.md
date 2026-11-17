# v111 — 撤销双引擎回到单引擎 + 引擎 109.3 中转层（治慢）

## 为什么
v110 的双引擎实验在真机上没成立：第二个引擎（Pages 真实页）在 App 的
内嵌 webview 里，从 110.0 到 110.6 连续七轮，队列始终建不起来
（setQueue 瞬时 CONTENT_EQUIVALENT、队列恒空）。它在场时还持续伤害
主引擎：它空闲的状态/进度推送（每 500ms 一次「没在播」）和真正放歌
的登录引擎抢界面——播放键来回跳、切歌无声、进度冻结。

她 16:24 明确要求「一次修改」：不再逐项打补丁，整段撤销；16:37 又
明确：老引擎「越播越慢」的问题也要在这一次里解决完再打包。

## 慢的根因（调研 + 代码对照后的定论）
网页版在 Safari 里秒播，App 内嵌引擎 9–55s 且逐首恶化。两边播放
代码同形（setQueue 传 ID 数组、串行 op 链），差别只剩网络路径：
网页版的 SW 把 *.music.apple.com 请求（MusicKit 自己的也算）全部
改道中转；打包引擎是直连苹果。SW 在 WKWebView 里结构性不存在
（110.4 真机实测 swctl=false；GitHub/苹果论坛调研一致），所以把
SW 的活下沉到 fetch/XHR 层做——110.5 的网络探针已在真机证明
MusicKit 的目录请求走 window.fetch、经中转能快速返回真实数据。

## 改了什么
### Swift（仅 v110 碰过的四个文件，全部回到单引擎形态）
- Player.swift：删掉 playback 引擎与 transport 路由，全部传输调用
  直连登录引擎；状态/进度/当前曲目/错误回调只接登录引擎一个来源
  （= v109 的接线）。删掉令牌转发与 playSongs 的补递令牌。
- EngineBridge.swift：删掉 EngineMode 双模式、Pages 播放页加载分支、
  onAuth 观察、setUserToken/pendingToken。保留：v109 在线更新、
  探针、授权弹窗、全部传输方法、call() 的 void() 包裹。
  另修两处：init() 补回 override 关键字（#12 构建实锤的编译错误）；
  新增 webViewWebContentProcessDidTerminate 处理——隐形 webview 的
  进程被系统回收后自动重载引擎，不再哑死到下次启动。
- RootView.swift：删掉第二个隐形 EngineHost，只挂登录引擎一个。
- SettingsView.swift：删掉「播放引擎」诊断行（回到 v109 的诊断面）。

### 引擎页 engine.html 109.2 → 109.3（唯一的功能性改动）
- 新增中转层：按 sw.js 的同一套规则改写 fetch 与 XHR——
  *.music.apple.com（js-cdn 除外）一律改道 AOI_CONFIG.relayBase，
  已指向中转的 URL 不二次改写。登录、串行 op 链、jump-first、
  109.1/109.2 的重试逻辑一律未动。
- 引擎经在线更新通道同步生效：已装的 v109/v110 下次启动也会拿到
  109.3（v110 的回落播放走的正是这个引擎）。

没动：登录流程、界面、收藏、AI、资料库、搜索、电台、首页、
小组件、APIClient。

## 自测
- Swift 四文件括号平衡；全项目 grep 无双引擎残留引用
  （player.playback / transport. / EngineMode / setUserToken 均为 0）。
- 引擎页全部内联脚本过 node 全量语法检查（不剥尾）。
- 新 harness（harness/engine_test.js）16/16：中转改写规则五条
  （api/amp-api 改写、js-cdn 与非苹果域名不改写、不二次改写、
  Request 对象 POST 带 body 改写）、XHR 两条、boot→ready→授权、
  playQueue 全量加载时 MusicKit 内部请求确实走中转、同队列
  jump-first 不重载。

## 装后验证
- 播歌有声、进度条走、播放键状态稳定不跳、切歌换歌有声。
- 重点看诊断日志：setQueue/play 的 settle 耗时应从 9–55s 量级
  降下来，且连续切歌不再逐首恶化；日志开头应有「relay layer on」。
- 播放页 player-engine.html 从此不再被 App 加载，停在 110.7 待命版。
