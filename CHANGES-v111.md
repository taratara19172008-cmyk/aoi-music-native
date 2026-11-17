# v111 — 撤销双引擎，回到单引擎（v109 的播放形态）

## 为什么
v110 的双引擎实验在真机上没成立：第二个引擎（Pages 真实页）在 App 的
内嵌 webview 里，从 110.0 到 110.6 连续七轮，队列始终建不起来
（setQueue 瞬时 CONTENT_EQUIVALENT、队列恒空）。它在场时还持续伤害
主引擎：它空闲的状态/进度推送（每 500ms 一次「没在播」）和真正放歌
的登录引擎抢界面——播放键来回跳、切歌无声、进度冻结。

她 16:24 明确要求「一次修改」：不再逐项打补丁，整段撤销。

## 改了什么（仅 v110 碰过的四个文件，全部回到单引擎形态）
- Player.swift：删掉 playback 引擎与 transport 路由，全部传输调用
  直连登录引擎；状态/进度/当前曲目/错误回调只接登录引擎一个来源
  （= v109 的接线）。删掉令牌转发与 playSongs 的补递令牌。
- EngineBridge.swift：删掉 EngineMode 双模式、Pages 播放页加载分支、
  onAuth 观察、setUserToken/pendingToken。保留：v109 在线更新、
  探针、授权弹窗、全部传输方法、call() 的 void() 包裹。
- RootView.swift：删掉第二个隐形 EngineHost，只挂登录引擎一个。
- SettingsView.swift：删掉「播放引擎」诊断行（回到 v109 的诊断面）。

没动：打包引擎页 engine.html（109.2）、登录流程、界面、收藏、
AI、资料库、搜索、电台、首页、小组件、APIClient。

## 自测
- 四文件括号/引号平衡；全项目 grep 无 playback 引擎残留引用
  （player.playback / transport. / EngineMode / setUserToken 均为 0）。
- AoiMusicApp 的 EngineBridge() 构造与新 init() 吻合。

## 装后验证
- 播歌有声、进度条走、播放键状态稳定不跳、切歌换歌有声。
- 已知代价（v109 的老 profile）：新队列首播要等几秒（今天实测
  setQueue 2.4s + play 5.3s 量级），同专辑内切歌走引擎内跳转较快。
- 播放页 player-engine.html 从此不再被 App 加载，停在 110.7 待命版。
