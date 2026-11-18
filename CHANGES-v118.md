# v118 定版清单（GPT 第 5 轮审查四份回复 + 逐条源码核实后收敛）

GPT 原始回复经逐条核实：行号大面积对不上、虚构了不存在的 SearchContentView.swift 与
WidgetConfiguration.swift；以下只收录核实属实或我自己读码确认的条目，被否条目附理由。

## 引擎 109.18（随 v118 打包 + 在线推送）
1. **initMK 失败永不重试（GPT C1-3，核实属实）**：configure 抛错后 mkInitStarted 不复位，
   mkPoll 永远被挡。改：catch 里复位标记 + 退避重试（1s/3s/8s，上限后停并报错）。
2. **自愈三漏洞（GPT C1-2，核实属实）**：
   a. 可信治好时漏删 healGiveUpLogged → 同歌再退化时 previewExhausted 不再发。补删。
   b. 可信门槛改 `d >= max(45, exp*0.6)`（45 与 60% 取大）。
   c. rebuildQueueAtCurrent 入 op 后先验目标 id 仍是当前项，不是则放弃本次（防切歌后重建错位）。
3. **电台 setQueue 超时后仍 play（GPT 第 4 份，核实属实）**：playStation 中 r1.timeout 只记日志
   仍继续 play → 可能播旧队列。改：超时即止（记日志、不 play、不设 wantPlay），并清 appQueueIds/
   queueSignature（电台独立上下文，GPT C1-5 的一半）。

## Swift
4. **动态封面（B4，日志实锤）**：prepareMotionFile 记录 export 的 error 域/码/描述；
   passthrough 失败 → 备选链：HLS 分段拼接（EXT-X-MAP+分段字节拼接存 mp4）→ 再失败记 miss；
   只挂「文件已就绪」的键；文件迟到就绪时重发布 nowPlayingInfo；「attached」日志只打真挂上的键数。
5. **静态封面下载（GPT C1-6，核实属实）**：lastArtworkKey 改为下载成功才置位（失败可重试）；
   回调发布前校验仍是当前歌曲，防旧封面盖新歌。
6. **弹窗（B3）**：主 webview 配置加 WKUserScript（atDocumentStart、forMainFrameOnly=false），
   每帧 alert/confirm/prompt 转发 aoi handler 记日志并吞掉（delegate 层保留）。
   GPT 第 4 份把「iframe 漏拦」降级为未坐实——此层同时是取证：再现时看有无转发日志定性。
7. **识曲（B2+第 4 份）**：start() 加 isStarting 防重入（GPT C1-4，installTap 重复装会崩）；
   会话激活成功后立即补一发 engine.play()（wasPlaying 时）——治「点下去那一刻停」；
   beginListening 各阶段 catch 记 NSError 域/码；no-match 记 SHError code（尤其 matchAttemptFailed）。
   GPT 的「常驻 .playAndRecord」其自己在 C3 已降为实验方案，本轮不采用。
8. **搜索框（B1）**：GPT 的根因叙事含虚构文件，不采信；按我方案改结构：搜索框移出 SearchView
   布局流，由 RootView 在 page==.search 时以覆盖层按顶部安全区钉住（横向对齐内容列），
   SearchView 内留等高占位并删掉自己的 keyboard shield（只留一层）。
9. **地区 toast（B5）**：handlePreviewExhausted 不再弹 preview_only toast，只记日志
   （GPT 的失败分类结论并入此决定：查无此歌 ≠ 地区锁定）。
10. **健康检查（GPT C1-3 后半，核实属实）**：pong 携带 ready 回传，ensureAlive 仅在
    ready==true 时判健康；ready==false 走未就绪路径（重启 probe/有界重载）。
11. **代际转发（GPT C1-2c，核实属实）**：previewHealed/previewExhausted 把 generation
    一并传 Player；Player 记录自己最近一次 playSongs 的代际，过期消息只记日志不执行换区版。
12. **资料库分页（GPT C1-7 部分属实）**：libraryPlaylists 与 include=catalog 的 librarySongs
    从 limit=50 改为 offset 分页拉全（沿用现有分页写法）；搜索加请求序号防乱序覆盖。
13. **跨区匹配（GPT C1-8，核实属实）**：resolveInStorefront 先全等归一化匹配，无命中才退子串包含。

## 精简（核实后，仅真死代码）
14. DownloadsView.swift 改名 FavoritesView.swift：该文件里根本没有 DownloadsView，
    装的是在用的 FavoritesView（首轮打包因此缺类型失败，已恢复并改名，代码一行未删）。
15. 删 EngineBridge.onQueue 死消息路径（无 JS 生产者、无消费者赋值）。
16. 否决项：GPT A1-3「删小组件 systemSmall 分支」——事实相反，两个 widget 都只注册
    systemSmall，她桌面用的就是小尺寸，删了即坏。GPT A2 的引擎队列合并、授权合并等深重构
    本轮不动（回归风险与收益不成比，GPT 自己也要求先回归）。IPA 体积结论（GPT A3）：
    源码行数对 IPA 影响仅约 50–100KB，大头不在代码，不做表演式精简。

## 不在本轮
- 队列 position/request-id 协议统一（GPT C1-5/C3）：方向认同，属结构重构，单独立项。
- setQueue 永久堵塞的引擎失联重建（GPT C1-1）：已有 ensureAlive 兜底，本轮只修电台超时续播。
