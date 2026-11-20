# 真实效果版落地页 | 100% 复刻 ASCII Motion 视觉

## 结论：可以复刻真实效果

ASCII Motion 的 hero 大字/点阵背景是运行时 JS 渲染的，Uncage 静态抓取拿不到（静态产物 hero 是黑的）。
但用 web-clone 的 `mirror --record` + `--offline` 可以把浏览器实际访问时加载的全部资源录下来（39 个资源、124MB），
离线回放时 0 个网络请求就能 100% 还原原站视觉——包括动态大字、粒子、应用界面预览和全部交互。

实测证据：
- 离线回放截图：原站大字 "ASCII / MOTION"、点阵背景完全渲染，0 个 504 miss
- 注入覆盖后：大字变成 "DELETE / NUL"，副标题替换，视觉与交互保持原站品质

## 交付形态

这是"镜像 + 注入覆盖"方案，不是纯静态文件：
- 依赖：`F:\web-clone\.web-clone\jobs\ascii-motion\runtime-cache`（124MB 录制缓存）
- 需要两个本地服务：离线镜像（4186）+ 干净落地页（4190）

## 启动

```bat
:: 1) 离线镜像（100% 原站视觉，不联网）
cd F:\web-clone
start node bin/web-clone.mjs job mirror ascii-motion --port 4186 --offline

:: 2) 干净落地页（纯静态备份，黑白灰）
cd F:\delete-nul\landing
start python -m http.server 4190 --bind 127.0.0.1
```

- 真实效果版：http://127.0.0.1:4186/ （需再注入覆盖脚本，见下）
- 干净备份版：http://127.0.0.1:4190/

## 注入覆盖（把原站大字/文案换成 delete-nul）

用浏览器 DevTools 控制台或 Playwright 执行 `inject.js` 里的逻辑：持续 rAF 覆盖两个大字 canvas（#2=360×120、#3=612×120）为 DELETE / NUL，并替换页面可见文案。

## 局限（如实说明）

- 覆盖靠 rAF 每帧重绘与原站动画竞争，需要一直运行
- 下方"应用界面预览"是原站 canvas 绘制的，里面的 "ASCII Motion" 字样无法用文本替换改掉
- 录制缓存 124MB 较大；换机器需重新 `--record` 录制
- 这是离线镜像+注入，不是可编辑源码；与黑白的干净版（index.html）是两套独立产物
