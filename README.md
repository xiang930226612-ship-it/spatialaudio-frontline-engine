# SpatialAudio Frontline Engine

这是一个可复用的 3D 空间音频引擎源码仓库，当前版本用于 `frontline` 客户端，把普通 3D 音效接到 SteamAudio HRTF 空间音频输出。

仓库包含：

- `src/`：SpatialAudio C++ 源码和头文件；
- `scripts/`：构建脚本、安装到项目脚本；
- `runtime/libc/`：当前已经编译好的 32 位运行时 DLL；
- `lua/`：Frontline Lua 适配层、调音文件、ClientMain 参考实现；
- `assets/`：导航 beep 音效和 frontline.csv 参考表；
- `third_party/`：SteamAudio SDK、miniaudio、stb_vorbis；
- `tests/`：简单加载/调音测试源码；
- `docs/`：详细接入、构建、API、修改说明。

> 建议仓库保持 private。`third_party/` 内是第三方组件，公开分发前请再次确认第三方授权要求。

## 最快使用

### 1. 编译 DLL

在 Windows PowerShell：

```powershell
cd D:\spatialaudio-frontline-engine
.\scripts\build_spatial_audio.ps1
```

成功后会生成/更新：

```text
runtime/libc/SpatialAudio.dll
runtime/libc/phonon.dll
```

### 2. 安装到一个 Frontline 项目

```powershell
.\scripts\install_to_project.ps1 -TargetRoot "C:\sfdeveloper-05-15"
```

这个命令会复制：

```text
libc/SpatialAudio.dll
libc/phonon.dll
resources/script/module/frontline/SpatialAudioAdapter.lua
resources/script/module/frontline/SpatialAudioTuning.lua
server/frontline/client/SpatialAudioAdapter.lua
server/frontline/client/SpatialAudioTuning.lua
audio/frontline/navigation/beep.wav
csv/frontline.csv.reference
```

默认不会覆盖目标项目的 `ClientMain.lua`，因为这个文件通常有项目差异。要手动参考：

```text
lua/resources/script/module/frontline/ClientMain.reference.lua
lua/server/frontline/client/ClientMain.reference.lua
```

如果确认目标项目可以直接覆盖参考版：

```powershell
.\scripts\install_to_project.ps1 -TargetRoot "C:\sfdeveloper-05-15" -WithReferenceClientMain
```

### 3. 独立客户端注意 `.lc`

如果客户端优先加载：

```text
resources/script/module/frontline/ClientMain.lc
```

那么合并 `ClientMain.lua` 后，必须重新编译/转换 `ClientMain.lc`，并更新补丁/manifest/MD5。否则会出现“编辑器生效，独立客户端不生效”。

## 文档入口

建议按下面顺序看：

1. `docs/PROJECT_STRUCTURE.md`：仓库结构说明；
2. `docs/BUILD_FROM_SOURCE.md`：从源码编译 DLL；
3. `docs/INTEGRATION_GUIDE.md`：怎么接入一个项目；
4. `docs/API_REFERENCE.md`：Lua 和 C++ 接口说明；
5. `docs/MODIFYING_ENGINE.md`：以后做别的项目怎么改；
6. `docs/TROUBLESHOOTING.md`：常见问题排查；
7. `docs/THIRD_PARTY.md`：第三方依赖说明。

## 当前默认策略

- 当前 DLL 默认只作为 Lua 模块使用；
- 公开导出入口是 `luaopen_SpatialAudio`；
- 普通 `SF_Audio_*` C API 默认不导出，只在 DLL 内部被 Lua wrapper 调用；
- 默认模块白名单是 `frontline`；
- 默认只允许通过 `csv/frontline.csv` 的 sound key 播放，不允许随便传绝对路径播放；
- 音频文件解析到 `项目根目录/audio/frontline/...`。

## 当前已包含优化

- PCM 共享缓存：同一个音效解码后复用，不给每个声源复制一份 PCM；
- 声源数量上限保护：保留高优先级、近距离、实际响度大的声源；
- 命令队列方案：Lua/API 线程只投递命令，音频线程消费命令，避免音频回调抢锁造成短静音；
- 前后调音参数在 Lua 中可改，不需要重新编译 DLL。
