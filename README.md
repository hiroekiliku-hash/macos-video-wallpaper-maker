# 壁纸制作器

把本机视频做成 macOS 动态桌面与屏保。仓库：[hiroekiliku-hash/macos-video-wallpaper-maker](https://github.com/hiroekiliku-hash/macos-video-wallpaper-maker)

## 下载

从 [GitHub Releases](https://github.com/hiroekiliku-hash/macos-video-wallpaper-maker/releases) 下载 `WallpaperMaker-macOS-arm64-v1.0.0.zip`，解压后运行「安装制作器.command」。应用为本地签名，未经 Apple 公证；安装脚本校验应用签名后复制到当前用户目录。

系统若拦截脚本：终端输入 `/bin/zsh `（含空格），把该脚本拖进去回车。不要全局关闭 Gatekeeper、SIP 或锁屏保护。

日常使用不需要 Xcode、Python、FFmpeg 或网络。生成与安装离线完成，不需要管理员密码。

## 要求

- Apple Silicon，macOS 26 及以上
- 组件与界面实测仅在 macOS 27 上进行

使用非公开 `com.apple.wallpaper` 接口，系统更新后可能失效。未做生成器的完整真实锁屏集成测试。

## 使用

1. 打开「壁纸制作器」，添加或拖入一段或多段 MOV / MP4 / M4V。
2. 填写名称，选择按列表顺序或随机播放；可上移、下移或删除。
3. 在「桌面效果」调节亮度、自然饱和度、饱和度、对比度；可切到「屏保原色」对照。默认「柔和」为较轻柔的桌面配色。
4. 用预览定位画面，点「用当前画面作封面」。未选时从首段视频自动取封面。
5. 选择输出文件夹，点「生成」。直接复制原视频以保留画质。勾选「同时生成分享 ZIP」可得到发给朋友的安装包。
6. 生成后点「安装」，在系统墙纸设置中选择你填写的名称，屏幕保护程序选「自动」。触发角仍在系统设置中调整。安装只处理这份作品，不会自动选定墙纸。

常见 H.264、HEVC 可直接使用。AVFoundation 无法播放的编码需先转为可播放的 MOV/MP4。生成过程中不要移动源视频。点「取消」时，大视频复制可能要等当前复制结束；ZIP 取消后，已生成的作品文件夹会保留。

## 功能

- **多段视频**：一份壁纸可含多段素材，顺序或随机播放。
- **桌面调色**：亮度、自然饱和度、饱和度、对比度只作用于桌面；屏保静音播放原色。
- **画面适配**：「铺满屏幕」裁切边缘；「完整显示」保留整段画面，比例不同会留边。旋转视频由 AVFoundation 处理方向。
- **缓停与续播**：退出屏保后视频逐渐减速停在桌面，画面参数平滑过渡。下次屏保从停住处继续并恢复原色。重启或系统结束壁纸扩展后会重新选片。
- **多份并存**：每份壁纸独立命名和安装。
- **重新打开**：文件 → 打开作品…，选择输出文件夹中的 `作品.json`，调整后重新生成。需保留作品文件夹里的应用和视频；只保留 JSON 无法再编辑。打开原作品可保留身份。
- **分享 ZIP**：朋友解压后运行「安装.command」即可安装该作品。
- **新建**：文件 → 新建。输出目录已有同名作品时，会创建带日期的新文件夹。独立新建的同名项目，安装器会提示换名。

命令行重新生成已有作品（可选）：

```text
壁纸制作器.app/Contents/MacOS/WallpaperMaker --create /绝对路径/作品.json --output /绝对路径/输出目录
```

加 `--no-zip` 只生成作品文件夹。

## 从源码构建

修改程序需要已安装完整 Xcode（脚本默认使用 `/Applications/Xcode.app`）。在源码目录执行：

```zsh
zsh build.sh
zsh package.sh
```

`build.sh` 编译制作器、壁纸宿主与壁纸扩展，并做本地签名。构建产物位于 `/private/tmp/WallpaperMakerBuild/壁纸制作器.app`；`package.sh` 在仓库 `dist/` 打出含应用、源码、「安装制作器.command」和「使用说明.txt」的 `壁纸制作器.zip`。升级 macOS 前请保留作品文件夹，必要时用新版制作器重新生成。

## 许可与素材

私有接口桥接与运行时模型参考、改编自 [Phosphene](https://github.com/kageroumado/phosphene)（MIT），说明见 `THIRD_PARTY_NOTICES.md`。仓库与安装包不含媒体或史努比素材。

项目采用 [MIT 许可](LICENSE)，第三方许可保持原样。具体检查与未验收范围见 [VALIDATION.md](VALIDATION.md)。
