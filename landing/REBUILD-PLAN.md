# delete-nul 落地页改造记录 | Rebuild plan

> 状态：rebuilt（干净重写 + 重建 ASCII 风格）。按 `web-clone` 的 product-adaptation 契约记录。

## 决策过程（为何是现在这个形态）

1. 最初复制 `web-clone` 的 `sites/voicestudio` 已验收模板逐项改造，但模板深度绑定 VoiceStudio 产品（语音库/渲染/Pro 定价），改造后留下空白区和不实文案 → 按用户决定推倒重写。
2. 用户追加要求：黑白灰配色 + ASCII loading 动画 + 接近 ascii-motion 的动画交互 → 重做动画版。
3. 用户要求"直接复用刚 clone 的 ASCII Motion 的 hero/页脚" → 验证后发现：
   - ASCII Motion 是 Next.js 应用，组件是编译后的 minified JS bundle，无可直接复制的组件源码；
   - 其 hero 的 ASCII 动态大字依赖运行时 JS 从 `/_next` 和数据端点取数，Uncage 静态抓不到（实测静态产物 hero 是黑的，运行时镜像 4183 才显示大字）；
   - 其页脚用 Tailwind 原子类 + 站点专属 CSS 变量，脱离原站 CSS 即裸样式。
4. 最终由用户确认：**delete-nul 内容 + 重建 ASCII 风格**。故采用：ASCII Motion 的**页脚 4 列结构**复用改造，hero 用重建的 canvas 字符引擎，整体黑白灰。

## 产物

- `index.html`：自包含落地页（~28KB，无外部依赖、无二进制素材）
- 预览：`http://127.0.0.1:4190/`（python -m http.server，临时）

## 复用的 ASCII Motion 元素（重建，非复制源码）

- Hero 双行 canvas 字标（DELETE / NUL）：**自制 8×10 超粗点阵字库**（D/E/L/T/N/U 手工设计，粗笔画），每个填充 bit 用 `@` 实心块渲染，叠加**白色霓虹发光描边 + 6 层 3D 挤出阴影 + 故障抖动**——达到原站那种粗壮立体感（黑白灰版）。对应原站 canvas "ASCII / MOTION"。自制点阵字体路线的最终方案，字母精确可控、不依赖原站编译代码。
- 页脚：**按原站结构复刻**——4 列（双色品牌字 / Product / Community / Connect 带社交 SVG 图标）+ 独立底栏（居中版权 + 右下主题切换按钮，明暗双主题都是黑白灰）。内容改为 delete-nul，配色黑白灰。
- 铺满 hero 的点阵 ASCII 背景（`· : + #`），随鼠标波动（对应原站 hero 大 canvas）
- 页脚 4 列结构：品牌介绍 / 产品 / 资源 / 连接（内容改为 delete-nul）
- 全站黑白灰配色（用户明确要求，非原站紫青）

## 内容真实性

所有文案来自 delete-nul 的 README/源码证据：精确匹配裸名、先列后删、`\\?\` 原理、三种模式、JSON/日志/超时、权限默认普通、FAQ 五问。无语音库/渲染/Pro 定价等未实现功能，无旧产品名残留。

## 验收（真实浏览器，非伪造）

四视口 320 / 390 / 768 / 1440：无横向溢出、控制台 0 错误、ASCII 字标与点阵背景渲染、loading 动画出现并消失、终端演示运行、reveal 全部显现（含 2.5s 兜底）、页脚 4 列完整。
reduced-motion 下所有动画退化为静态、loading 跳过。

## 如实声明

- Hero 字标是 canvas 代码生成的重建效果，不是 AI 生图，也不是原站组件源码
- 未做在线发布；本地预览 ≠ 上线

*Note: 改造中途曾误删本文件一次，此为重建版，记录最终决策。*
