# 验证范围

当前版本在 Apple Silicon、macOS 27 环境完成以下检查：

- 两段短视频的作品生成，含中文、空格和单引号名称。
- 手机视频旋转元数据、竖屏封面与真实解码输出。
- 多段循环、缓停、持帧、恢复原色续播。
- 生成应用的完整代码签名、安装器 `--verify-only` 和分享 ZIP 生成。
- AppKit 界面的多视频导入、桌面/原色对照、竖屏留边预览。
- 制作器本身安装到当前用户应用程序目录后打开。

上述检查没有把合成测试视频注册、选择为真实系统壁纸，也没有完整验收生成器的同名壁纸升级流程。macOS 26 是声明的最低版本，未做独立实机验证；请勿把编译成功解释为所有系统版本均已验证。

原有实验中的壁纸引擎有真实锁屏/解锁缓停事件记录，但这不等于任意用户视频的系统集成都已验证。

`Tests/EngineSmoke.swift` 是通用引擎的针对性测试程序，需要自行准备包含两段短视频（第二段带竖屏旋转元数据）的生成作品；测试不会自动选择系统墙纸。发布仓库不包含测试视频或本机运行日志。

## 1.0.1 内存回归（macOS 27.3）

- 实际视频、连续换片 180 秒的独立进程物理 footprint 在预热后约 58.8–67.3 MiB；释放渲染器后约 42.0 MiB。持帧与重新加载解码器后的续播检查通过。
- 100 次预览实例创建/退役测试：短时重连复用实例，空闲数量最多为 2，超时后实例和请求索引归零。
- 200 次 1080p 快照对象创建/释放检查未观察到快照帧线性保留；此路径未修改。
- 这是限时回归，不能替代整天运行的稳定性证明。旧版本的单播放器短测也未复现报告的 7–8 GB 增长，不能把这次记录描述为已复现并精确定位了所有旧问题。

可在有完整 Xcode 的 Mac 上使用自己的生成作品复跑内存探针（不包含测试视频）：

```zsh
xcrun swiftc -swift-version 5 -parse-as-library -framework Cocoa -framework AVFoundation -framework IOSurface Engine/WallpaperConfiguration.swift Engine/ContinuousRenderer.swift Tests/MemorySmoke.swift -o /tmp/WallpaperMemorySmoke
/tmp/WallpaperMemorySmoke '/你的作品/壁纸.app/Contents/Extensions/VideoWallpaperExtension.appex/Contents/Resources' 180 /tmp/memory-report.json
xcrun swiftc -parse-as-library Engine/SurfaceRegistry.swift Tests/SurfaceRegistrySmoke.swift -o /tmp/SurfaceRegistrySmoke
/tmp/SurfaceRegistrySmoke
```

本机另已安装史努比 1.0.3（同一修复引擎）并在系统中选用、观察实际画面，扩展连续 150 秒物理 footprint 约 64.8–74.5 MiB，含设置页预览；未做整天观察或重复锁屏验收。制作器 1.0.1 同时安装。
