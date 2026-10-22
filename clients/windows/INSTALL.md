# 庄Sir采访录制助手 · Windows

完整解压后直接打开 `ZSirCapture.Windows.exe`，无需安装.NET、运行CMD、配置PATH或联网下载录制工具。请保持tools子目录和其他文件完整，不要只复制EXE。升级前停止保存并退出旧版，解压到新目录；已有素材不会删除。

支持桌面画面及系统播放声音，暂不支持摄像头/麦克风录制。素材默认位于“视频/ZSir Recordings”。请先短试录确认声音和所选屏幕。异常时保留中间素材。

x64要求Windows10 2004+；ARM64要求Windows11 ARM，应用与.NET为ARM64，所带FFmpeg工具为x64，依赖系统仿真。不能将x64测试结果当成ARM64实机验收。

本包未发行签名，请核对来源并遵循系统提示，不关闭系统安全保护。自有代码MIT；.NET许可见licenses；编码工具许可及来源见tools/FFmpeg-LICENSE.txt、tools/x264-LICENSE.txt和tools/SOURCE-NOTICE.md。
