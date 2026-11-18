# v117 修复清单（GPT 审查第 4 轮定版，2026-11-18；GPT 指认已逐条对源码核实）

## 恢复所有权统一（问题 1，确定）
- 引擎成为唯一恢复决策者：previewHealTick 治好后 post 专用消息 previewHealed（带队列代际）；两次失败 post previewHealExhausted。
- Player.checkPreviewClip 降为纯观察（徽标），删除其自行 forceReload 的路径；foregroundBecameVisible 不再下令重建。
- 跨区换版（stage-2）只由 previewHealExhausted 触发；收到 previewHealed 即清该歌徽标/状态。
- 引擎 forceReload 入口自检：当前资产已完整 → 只 play 不重建。

## 起播确认补漏（问题 2，基本确定）
- wantPlay 在所有播放意图路径置真（playQueue 同歌快速路径、jumpTo 同歌路径此前漏设——已核实）。
- playVerify 增加 expectedItemId：无 nowPlayingItem 时按预期目标判起播失败，不再直接退出。
- 试听自愈重建期间暂停起播补发，避免两个恢复动作交替。

## 识曲音频会话（问题 3，基本确定；含本地已备补丁）
- teardown 新增 restorePlaybackAudioSession()：恢复 .playback + .mixWithOthers + setActive(true)，之后才 force 续播。
- stop() 与 handleMatch() 共用 teardown 恢复（handleMatch 此前从不恢复——已核实）；聆听中 force 续播检查保留。

## 引擎失联自愈（问题 7，确定缺陷）
- 已核实：probe() 在首次 ready 后永久停摆；内容进程终止后只 reload、无人等它回来。
- probe 在进程终止后重启；回前台 ensureAlive()：healthCheck(nonce)→pong，约 4 秒无响应才限次重载（退避，防死循环）。
- authStateKnown 三态：未知时界面显示「引擎恢复中」，不再误报「未连接」、不弹连接账号提示。
- RootView 回前台先 ensureAlive，握手恢复后再走 Player 前台逻辑。

## 动态封面（问题 4，不确定——先取证再谈修法）
- 日志打出 supportedAnimatedArtworkKeys 的实际内容（此前只记「没有 1x1」）。
- pickMotionURL 拆 square/tall 两路；系统给哪个键就写哪个（1x1/3x4 独立 artworkID）；每首重试保留（低成本探测）。

## 闪退面（问题 5，不确定——无 .ips 不下结论）
- prepareMotionFile 按歌曲合并 in-flight 任务（预取与系统回调此前可并发写同一文件——已核实），临时文件写完再原子移入。
- Player.swift:945 cachesDirectory .first! 改 guard（已核实存在）。
- 仍需她提供 AoiMusic*.ips 或 JetsamEvent*.ips 才能定性。

## 弹窗（问题 6，基本确定 v116 方向正确）
- alert 拦截日志加 frame host；补 confirm / text-input 两个面板的安全默认实现。

引擎版本随本轮升至 109.16（previewHealed 等消息 + healthCheck + wantPlay 补漏）。
