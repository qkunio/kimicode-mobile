# 推广视频

`kimicode-mobile-promo.mp4`（16:9，1920×1080）与 `kimicode-mobile-promo-9x16.mp4`（竖屏，1080×1920）：30fps / 42 秒，两版时间线与音轨完全相同，白底 + 衬线标题（Noto Serif SC）的风格；所有音效与钢琴配乐都是 `sfx.py` 现场合成的（无采样素材）。

| 文件 | 作用 |
|---|---|
| `index.html` | 动画本体：`seek(t)` 按时间确定性渲染每一帧，同时导出音效提示表 `CUES`。直接用浏览器打开可实时预览，加 `?portrait` 看竖屏版 |
| `render.mjs` | Playwright 逐帧截图 → ffmpeg 编码（无声），并写出 `cues.json`。字体请求由 Node 代取，没加载上 Google Fonts 会直接报错，不会悄悄回退成系统字体 |
| `sfx.py` | numpy/scipy 合成音效 + 钢琴独奏配乐（87 BPM，C 大调，片尾和弦正落在最后一下），按 `cues.json` 混成 WAV |

重新生成：

```bash
pip install numpy scipy
# 走 HTTPS 代理的环境再加 NODE_USE_ENV_PROXY=1，否则字体取不下来
NODE_PATH=$(npm root -g) node render.mjs video.mp4 30              # 16:9；需要全局 playwright 与 ffmpeg（或 FFMPEG=路径）
NODE_PATH=$(npm root -g) node render.mjs --portrait video-v.mp4 30  # 9:16
python3 sfx.py cues.json audio.wav
ffmpeg -i video.mp4 -i audio.wav -c:v copy -c:a aac -b:a 256k -shortest -movflags +faststart kimicode-mobile-promo.mp4
```

竖屏版把最后一步的 `video.mp4` 换成 `video-v.mp4`，输出名改成 `kimicode-mobile-promo-9x16.mp4`。
