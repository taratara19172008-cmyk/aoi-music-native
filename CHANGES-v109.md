# v109 — 播放装载提速（同队列跳转）+ 引擎在线更新 + 桥接噪音清理

起因：v108 装机后播放仍有问题，用户发来设置页诊断截图（2026-11-17 12:04），三条实锤：

1. **playQueue settle 耗时 9153ms / 55041ms**——MusicKit 在 WKWebView 里装载一次队列要 9~55 秒。串行链没卡死、setQueue 也没被打断，纯粹是慢；用户连点的操作全堵在后面排队，于是「越来越严重」。
2. 满屏 `call failed: JavaScript execution returned a result of an unsupported type`——桥接噪音（见 3）。
3. 小组件通道：不可用（签名未包含 App Group）——SideStore 免费签名剥除 App Group，代码无解，付费开发者账号签名才能活。本版不动小组件。

## 1. 同队列切歌改「队列内跳转」（engine.html）

playQueue 的 op 内新增 jump-first：请求列表与 MusicKit 已装载队列 id 完全一致（同序）且随机播放关闭时，直接 `changeToMediaAtIndex(start)` + `play()`，不再整队 setQueue 重装——镜像网页版播放器的做法。任何不一致、随机开启、或跳转抛错，都回退到原 setQueue 全量路径（跳转失败有日志）。模式（随机/循环）仍按下单时刻的捕获值在跳转后应用。node harness 20 项全过（同队列跳转/异队列/随机/跳转失败回退/合并跳过/慢 setQueue/部分不一致）。

注意：换歌单、换专辑时仍要付一次 setQueue 装载（9~55 秒是 MusicKit 在此环境下的实测值，非本代码可控）；同专辑/同歌单内切歌从此走廉价路径。

## 2. 引擎在线更新（EngineBridge.swift）

用户 12:08 提问、12:10 批准的方向。引擎页启动加载改为：优先用 Application Support 里缓存的在线版（完整性校验：须含 AoiEngine/AOI_CONFIG/ENGINE_VERSION 三标记），无缓存或校验失败用打包版兜底；加载方式不变（loadHTMLString + music.apple.com 源，登录路径零改动）。启动后后台从仓库 raw 地址拉最新 engine.html（绕缓存、15s 超时），内容不同且校验通过才写入缓存，**下次启动生效**（不在会话中途换引擎，避免打断播放与授权状态）。设置页诊断新增一行「引擎版本： vX（在线更新/内置）」，下载成功时日志记 `engine update vX downloaded, applies next launch`。引擎版本号独立于构建号：本版引擎为 109.0，今后纯引擎修复递增小版本推仓库即可，用户杀掉重开 App 生效，不再重装。

## 3. 桥接噪音清理（EngineBridge.swift）

`call()` 的 JS 统一包 `void (...)`：引擎方法返回 Promise，evaluateJavaScript 无法桥接 Promise 结果，每次传输调用都报 unsupported type（命令其实都执行了）。authorize() 早已用 void 包裹，本次推广到全部调用。日志从此只剩真信号。

## 未动

登录/授权/init 路径、Player 传输层、串行 op 链与合并逻辑（v108 已验）、小组件、图标、电台布局、专辑页歌手跳转、收藏工人、MarqueeText 缓存。
