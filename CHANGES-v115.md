# v115 变更清单（引擎 109.12）

GPT 三轮讨论（全量审查 13 条 + 掉授权专题 + 试用反馈专题）收敛后的一次全量修复。

## 播放核心 / 掉授权（引擎 109.12 + Player + EngineBridge）
- 引擎：授权快照日志（configure / authorize 前后 / 恢复前后，只记 isAuthorized、storefront、令牌有无，永不记值）；页面回前台（visibility visible / pageshow）向 Swift 发 foreground 信号并刷新授权状态；新增 `AoiEngine.authState()` 与 `AoiEngine.recoverAuth()`——恢复只在引擎确认未授权时才调 authorize()，且在串行 op 链内执行，永不与 setQueue 交错。
- Player：试听（30 秒）处理重做为状态机——先探测授权（/v1/me/library/songs 探针：401=真掉授权→走授权恢复；200=授权正常→才做同曲跨区解析；网络失败→前台重排当前队列重新拿许可证）；"已换国区版"提示只在恢复后实测为完整时长时才弹出；试听标记只在 onProgress 确认完整时长、或无关歌曲接管时清除，恢复尝试本身不清。回前台（引擎信号 + scenePhase）同样触发这套自检（20 秒节流）。
- checkPreviewClip 的队列位置改用当前 index；playSongs 的过滤后位置改按「目标前可播歌曲数」计算（修重复歌曲错位）；异步恢复带队列代次校验，过期结果丢弃。
- EngineBridge：脚本消息处理器改弱代理（解引用环）；WebContent 终止时先记录终止前的授权状态再重载。

## GPT 审查 13 条的落实
- 必修：NowPlaying 分享链接去强制解包（解析失败走备用、再失败隐藏按钮）；AIClient JSON 截取加范围守卫；resolveInStorefront 搜索词严格编码（urlQueryAllowed 减去 &=+#%）并同步修 search()；艺术家匹配拒绝空艺术家；albumIdentity 改 Optional（标题+艺术家齐全才有身份）；全部专辑收藏显示点改用 isFavAlbumItem（CollectionView 两处 + Components 长按菜单）；Shazam 识别失败路径不再搁浅状态。
- 建议：引用环弱代理（已做）；专辑取消收藏按双 ID 空间分别删除（目录 id / 资料库 id 各用其 id，404 视为该空间已达目标状态；rateDelete 本身也对 404 宽容）；BgCropView 渲染加几何守卫。
- 不做：第 1 条并发隔离（Swift 5.0 语言模式下不成立，GPT 二轮已认同）。

## 小组件
- 播放/暂停/切歌迁移到 AudioPlaybackIntent：新增 AoiWidget/PlaybackIntents.swift，主应用 target 通过 pbxproj 同步组+例外集共享同一份 Intent 定义，系统在应用进程执行，直接驱动 Player；小组件进程内执行时回退到原 App Group 命令通道。
- 按键改为居中成组、与边缘留足距离；封面改为完整显示（scaledToFit）浮于自身模糊底图之上；播放/暂停图标加符号过渡。
- 识曲小组件加重复脉冲符号动效（WidgetKit 允许的上限；持续视频动画是平台硬限制，做不到）。

## Shazam
- 按钮从首页问候旁挪到左栏最上方（RootView 顶层左上角，居中于栏宽）。
- 录音会话改 .mixWithOthers：不再打断手机上其他应用的音乐；也不再自动暂停自己的播放（GPT 三轮确认原因为 options: [] 的 nonmixable 语义 + 代码主动暂停，两处都改）。
- 状态反馈：开始聆听有 toast，聆听全程顶部中央有动画声波条 +「正在聆听」胶囊。
- 识别成功改发本地通知：封面附件 + 歌名 + 艺人（音乐卡片），点通知才进应用播放；不再自动开播。通知权限在首次识别成功时申请，前台也弹横幅（UNUserNotificationCenterDelegate）。

## 界面
- 封面溶边重做：主体保持清晰，只有顶部和底部窄带（约 12%/14%）模糊并淡出（共享 heroEdgeMask / heroEdgeBlurMask，专辑/歌单/艺人页统一；动态封面只走淡出罩）。
- 搜索栏复原到原位置（布局流内、滚动区上方），整页忽略键盘 inset，点输入框不再上弹（v114 悬浮层把安全区算了两遍、低了约 47pt 且压住「最近搜索」标题）。
- 左滑删除改苹果原生样式：红色矩形贴边、等高、无内嵌圆角，继续滑会弹性拉伸，整行滑满直接触发删除；回弹换原生感弹簧。
- 图标：黑胶改纯红唱片（红盘面、红纹、同色系沟槽、深红标签），光线加强（宽幅斜射光带 + 左上高光 + 边缘轮廓光），全部平滑渐变——程序校验盘面内零近白像素、无任何白点噪点；eq 与版式不变。

## 锁屏动态封面（iOS 26）
- Player.updateNowPlayingInfo 接入 MPMediaItemAnimatedArtwork（1x1 键）：预览图用静态封面，视频由系统按需回调——把专辑动态封面（HLS）用 AVAssetExportSession 直通导出为本地 .mp4 缓存后返回文件 URL。系统不支持或失败时自动回落静态封面。
- 顺带修：静态封面不再被每次状态事件清空（旧代码每次都把 artwork 键置 nil，锁屏封面会随播放/暂停闪失）。

## 待真机验证（重点）
小组件三键（应用在后台/挂起时点按是否生效、图标是否跟随状态）、掉授权自恢复（日志 auth[...] 快照与恢复路径）、四首曾变 30 秒的歌、Shazam 识别其他应用扬声器音乐且不打断、锁屏动态封面、溶边窄带、搜索栏位置与点击、左滑手感、图标无白点。
