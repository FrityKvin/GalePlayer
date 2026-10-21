# TestMedia

调试 Gale Player 时用的测试媒体（视频 / 音频 / 截图）放这里，**不要放到 `~/.hermes` 的 scratch 目录**。

- 本目录内容已被 `.gitignore` 忽略，不会提交进仓库（视频体积大，且与代码无关）。
- 调试 + 发布完成后，**主动问 Kevin 要不要清理**，不要自行删除。
- 常用素材可用 `ffmpeg` 现生成：4K/HDR 测试片、彩条图（用于验证旋转/镜像方向）、AV1/HEVC 10bit 等。
- 历史踩坑：曾把测试视频放在 `~/.hermes/profiles/reabot/cache/scratch/mediatest/`（约 380MB，含 333MB 的 4k.mp4），与项目脱离、事后难追溯 —— 所以统一放回仓库内。
