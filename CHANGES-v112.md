# v112 — GPT 全量审查后的修复轮（2026-11-17 晚）

背景：引擎 109.9 真机第三首点歌爆炸（setQueue 67.6s + play 77s，10 秒定时器 77 秒才触发）。Codex 登录失效（OpenAI 新会话强制手机验证、+86 收不到码、用户拒绝电话路），改由 ChatGPT 网页版（深入思考）通读简报 + 全部 25 个源码文件审查；其结论经 Muse 逐条与源码核对后属实，本轮按其路线实施：先确诊、再修队列生命周期、Swift 修复打包。

## 引擎 109.10（在线更新，先行生效）
- 诊断：新增 1 秒 JS 心跳（gap>2.5s 打日志，附 visibility/hidden）、visibilitychange/pagehide/pageshow 日志、fetch/XHR 慢请求日志（>3s 或 ≥400，只记方法+host/path+状态+耗时，不记 token/参数）、setQueue 超 20 秒的纯观察日志（不重发、不打断）。
- 中转层改运行时开关，默认直连（GPT：原生引擎 v58–v108 一直直连，中转从未同条件 A/B；直连同时去掉共享出口 IP 被限流的嫌疑）。`AoiEngine.setRelay(true)` 可切回，localStorage 持久化。
- 队列修改互斥：setQueue 与 playLater 补队列共用一把 mutate 锁；在途的补队列块先落地旧队列、随后被新 setQueue 整体替换——旧歌不再可能追加进新队列；补队列的过期检查在锁内紧贴调用点重验。harness 的 stale 测试改为断言完整队列。
- 修重复点歌 bug（GPT Q5.2）：同歌单同歌再点只 play，不再 bump 世代号废掉在途补全；同歌不同歌单则重建队列（此前早退导致 MusicKit 播旧单、界面显新单）。世代号只在真正建队时 bump，点歌合并改用独立序号。
- jumpTo 删除 changeToMediaAtIndex 兜底（已证可无限挂起的 API 彻底移出控制链）；无队列上下文时报错返回。
- 电台 playStation 的 setQueue/play 加有界观察等待与超时日志。
- MediaSession 动作处理器只在 configure 与切歌时注册（此前每 500ms 重注册）。

## Swift（随本 IPA 生效）
- 引擎宿主 opacity 0.01 → 1，webView 改透明（isOpaque=false）：消除「近透明页面被 WebKit 当不可见而节流」的嫌疑（GPT 根因排序第 1 位的具体机制）。
- 锁屏/控制中心：Play 与 Pause 不再同接 togglePlay，新增 playOnly/pauseOnly 单向控制（GPT Q5.8 实锤 bug）。
- 进度回调去重：duration/isPlaying 仅变化时才发布，减少整棵视图树每 500ms 重渲染。
- 封面图按歌曲缓存，updateNowPlayingInfo 不再每次事件重复下载同一封面。
- WebContent 进程终止恢复时一并重置 authorized（新页面重新上报授权状态）。
- call() 在引擎未就绪时打日志（此前命令被守卫静默丢弃）。
- 设置页日志 80 行随本包落地（源码早已改好，旧 IPA 滞后）。

## 验证
- harness 46 项全过（含 5 项新测：默认直连/开关、重演同歌保补全、同歌异单重建、无队列 jumpTo 拒绝、stale 完整队列断言）。
- 引擎全文 node 语法检查通过；线上文件推送后逐字节核对。

## 待真机验收
- 点歌速度与第三首是否还爆炸（心跳日志会直接点名：若再卡，看日志里有没有 heartbeat gap / net 慢请求 / setQueue pending 三类标记即可定位）。
- 锁屏播放/暂停方向、引擎页全透明后界面无异常。
