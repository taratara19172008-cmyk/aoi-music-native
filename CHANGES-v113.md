# v113 — 引擎 109.11（D 方案提速）+ 界面轮（GPT 审查后续）

承接 v112 真机验收：播放已稳（点歌 2.9–5.9s、play 42–102ms 落地；66s 心跳
冻结发生在应用切后台时，证实 WebKit 隐藏节流，与前台播放无关）。

## 引擎 109.11（在线更新，杀掉重开即生效）
- **D 方案落地**：点歌时 Swift 把被点歌曲的完整 API 资源一并交给引擎，
  引擎改用 `music.setQueue({ items: [resource] })` 装载队首。已对 MusicKit
  v3 源码逐行核实：`convertToItemDescriptors` 只对 `{item}/{items}` 形式把
  资源转成带 `data` 的描述符，`loadResources` 对带 data 的描述符**跳过
  目录请求**；`{songs:[...]}` 形式则把条目原样当 id，传对象必坏，故不用。
  仅目录歌曲（type == "songs" 且 playbackId == id）走此路；资料库歌曲仍走
  id 形式。data 形式失败自动回退 id 形式（含原有的丢弃不可解析保护）。
  日志会标注 `(via data)` / `(via ids)` 以便真机对比耗时。
  急停开关：localStorage `aoi-dataq` = `0`。
- harness 新增 5 项检查（data 形式零目录请求、失败回退、资源 id 不符时
  忽略），共 51 项全过。

## 播放页背景与封面同色（真 bug：调色板红蓝通道颠倒）
- CoverPaletteLoader 旧代码把 UIGraphicsImageRenderer 的像素字节按
  R,G,B 顺序读，设备上实际内存布局是 B,G,R（byteOrder32Little）——
  于是每张封面算出的背景都红蓝互换：崔健的红色封面把播放页刷成蓝色，
  沐月的水下青色封面刷成橄榄卡其。用两张真封面离线复算验证：旧算法
  数值与截图背景逐一吻合，互换通道后与封面一致。
- 改为显式 RGBA 位图上下文采样（byteOrder32Big + premultipliedLast，
  内存布局锁定 R,G,B,A）；顶部向白色提亮由 0.18 降到 0.12，色相更贴
  封面本身。此修复同时惠及歌手页 / 专辑歌单页的整页取色背景。

## 封面边缘深度融入（歌手页 / 专辑页 / 歌单页）
- hero 底部新增一层封面自身的模糊副本（blur 16，渐变遮罩 0.42→0.85
  才显现）：先让画面自己的像素溶散，再由颜色渐变接管，不留任何边缘。
- 颜色渐变的溶入段拉长（0.40 起，多一档中间停靠点）。配合上面的通道
  修复，溶入色与封面边缘真正同色。

## Swift
- Player.playSongs / EngineBridge.playQueue：新增 targetJSON 通道（上述）。
- **首页按 Apple Music 官方层级重排**：问候语 → 最近播放（提到最前，卡片
  118→140）→ 推荐歌单改大卡 hero 横滑（272 宽）→ 推荐歌曲 → 热门歌曲 →
  热门专辑 → 推荐组 → 个人推荐栏（More by / Latest from / Fans also like）。
- **电台页 ghost cells**：recommendations() 与 recommendationGroups() 的
  过滤改为「必须有非空标题」（原先只有封面、没名字的条目也会渲染成空白
  卡）；RadioView.load() 再对电台与歌单列表各过滤一次（含排行榜歌单）。
- **标题省略号**：MarqueeText 的首次测量可能落在页面转场动画中途，缓存了
  错误的「放得下」结论，过长文本于是被静态文本截断成省略号而不是滚动
  （艺人页 Top Songs 即此）。新增：布局稳定后（350ms）自动复测一次。
- **喜爱页收藏专辑**：由两列网格改为与资料库一致的三行横滑栏（46 图 +
  标题/歌手行），长按菜单带打开 / 播放全部 / 取消收藏。
