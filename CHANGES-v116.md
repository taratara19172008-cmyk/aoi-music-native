# v116 变更清单（引擎 109.13）

v115 真机反馈的六条，一次修完。

## 1. 30 秒试听——这次找到了真机制（引擎 109.13 + Player）
她 09:05 的日志是决定性证据：`auth[configure] isAuthorized=true、storefront=cn、mut=yes`——**授权没掉**；但引擎内目录请求慢到 26 秒/个、setQueue 16 秒，`MEDIA_KEY` 弹窗也出现了——**是许可证（webPlayback/FairPlay 密钥）获取在限流窗口里失败，MusicKit 拿 30 秒试听顶替**。而 v115 的恢复走 playQueue，被引擎的"同列表同歌曲"捷径挡成"只播放"，根本没重新拿许可证——恢复是空转。
- 引擎新增试听自检：每 500ms 对比"已加载资源时长 vs 目录时长"，确认是试听版就**强制重建队列重新拿许可证**（绕过捷径），并把播放位置 seek 回去；每首歌最多 2 次，只在页面可见时做，全程日志可查（`preview heal: ...`）。
- Swift 的恢复路径（前台自检、授权恢复后重播）改调引擎 `forceReload()`，不再走会被捷径吞掉的 playSongs。
- 恢复分两段：先强制重拿许可证；8 秒后仍是试听，才走第二段"跨区同曲替换"（原来的解析逻辑降为 stage 2）。
- 后台补队列在页面 hidden 时暂停（26 秒的请求都发生在 hidden 窗口，补队列的洪流还会毒化许可证通道），回前台自动续。

## 2. MEDIA_KEY 弹窗
MusicKit 把致命 DRM 错误经 `window.alert` 抛出（就是那个 `[object Event]` 原生弹窗）。引擎在 MusicKit 加载前重定向 alert → 进日志且触发试听自检；EngineBridge 同时实现 JS alert 的 WKUIDelegate 方法，只记日志不弹窗，双保险。

## 3. 搜索框上弹
v115 把键盘屏蔽加在 SearchView 内部，但它的祖先层还在为键盘收缩。改到 RootView 最外层、且仅在搜索页生效（`.ignoresSafeArea(.keyboard, edges: page == .search ? .bottom : [])`），AI 聊天等页面的键盘行为不受影响。

## 4. 播放页下拉闪烁
下拉手势挂在会被偏移的页面内部，局部坐标系的 translation 与 offset 互相喂数→闪烁。手势改用全局坐标系（`coordinateSpace: .global`），手指在屏幕上的位移与页面偏移解耦。

## 5. 识曲不停音乐
v115 的混音会话仍可能被"激活录音会话"这一下把 webview 播放顶停。Shazam 开始前记下播放状态，激活后 0.4s/1.7s 两次检查、结束时再检查一次：若是被顶停的，静默恢复播放（Player.resumeAfterInterruption）。

## 6. 小组件按键
真因是算术：v115 的居中组总宽 196pt（3×52 按键 + 2×20 间距）塞进约 158pt 的小尺寸小组件，对称溢出把左右 glyph 顶出边界被圆角切掉。小尺寸改 40pt 按键 + 12 间距（共 144pt，留有余量）；大尺寸改等距 Spacer 分布（52pt 按键），不贴边也不挤成一团（按她补充的标准：不要太聚拢，左右不贴边界即可）。

## 待真机验证（重点）
之前变 30 秒的歌（放着放着看日志有没有 `preview heal` 触发并恢复完整时长）、MEDIA_KEY 不再弹窗、搜索框点开不跳、播放页下拉不闪、识曲时音乐不断、小组件按键（小尺寸不被切、大尺寸分布均匀）。
