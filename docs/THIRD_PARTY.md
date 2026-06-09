# 第三方依赖说明

本仓库按要求包含第三方依赖，方便以后换电脑或新项目直接编译。

## SteamAudio

路径：

```text
third_party/steamaudio
```

用途：

- HRTF binaural 空间音频处理；
- 编译需要 `include/phonon.h` 和 `lib/windows-x86/phonon.lib`；
- 运行需要 `lib/windows-x86/phonon.dll`，构建脚本会复制到 `runtime/libc/phonon.dll`。

SteamAudio 自带第三方说明文件：

```text
third_party/steamaudio/THIRDPARTY.md
```

如果仓库要公开发布，请先确认 SteamAudio SDK 的再分发条款。

## miniaudio

路径：

```text
third_party/miniaudio/miniaudio.h
```

用途：

- 打开系统音频输出设备；
- 音频回调；
- wav 解码。

## stb_vorbis

路径：

```text
third_party/stb_vorbis/stb_vorbis.c
```

用途：

- 解码 ogg/vorbis 音频。

如果项目 CSV 中完全没有 ogg，也可以不用它，但当前构建脚本会自动 include。

## 覆盖第三方路径

默认使用仓库内第三方。也可以设置环境变量：

```powershell
$env:STEAMAUDIO_SDK_DIR="D:\deps\steamaudio"
$env:MINIAUDIO_DIR="D:\deps\miniaudio"
$env:STB_VORBIS_DIR="D:\deps\stb_vorbis"
```
