# 项目结构说明

```text
spatialaudio-frontline-engine/
  src/
    SpatialAudio.cpp
    SpatialAudio.h
  scripts/
    build_spatial_audio.ps1
    install_to_project.ps1
  runtime/libc/
    SpatialAudio.dll
    phonon.dll
  lua/
    resources/script/module/frontline/
      SpatialAudioAdapter.lua
      SpatialAudioTuning.lua
      ClientMain.reference.lua
    server/frontline/client/
      SpatialAudioAdapter.lua
      SpatialAudioTuning.lua
      ClientMain.reference.lua
  assets/
    audio/frontline/navigation/beep.wav
    csv/frontline.csv
  third_party/
    steamaudio/
    miniaudio/miniaudio.h
    stb_vorbis/stb_vorbis.c
  tests/
  docs/
```

## src

`src/SpatialAudio.cpp` 是核心实现，包含：

- SteamAudio HRTF 初始化和处理；
- miniaudio 输出设备；
- wav/ogg 音频解码；
- `frontline.csv` sound key 到音频路径映射；
- PCM 内存缓存；
- 声源播放、循环 named source、一次性 playOnce；
- 声源上限保护；
- 命令队列；
- Lua module wrapper。

`src/SpatialAudio.h` 声明了内部 C API。默认编译时这些 `SF_Audio_*` 不导出给外部，只给同一个 DLL 内的 Lua wrapper 调用。

## runtime

`runtime/libc` 是当前已编译好的运行时。接入到项目时复制到目标项目：

```text
目标项目/libc/SpatialAudio.dll
目标项目/libc/phonon.dll
```

## lua

Lua 适配层是普通项目最常改的地方：

- `SpatialAudioAdapter.lua`：加载 DLL、初始化、封装 `playOnce` / `playNamed` 等；
- `SpatialAudioTuning.lua`：坐标轴、增益、前后听感参数；
- `ClientMain.reference.lua`：已经接好新引擎的参考版，不建议无脑覆盖生产项目，要按差异合并。

## assets

`assets/audio/frontline/navigation/beep.wav` 是新增启用的导航音效。

`assets/csv/frontline.csv` 是参考资源表。目标工程已有自己的表时，不要直接覆盖，至少合并导航 beep 行。

## third_party

为了以后换机器也能编译，第三方依赖也放进来了。构建脚本会优先使用仓库内 `third_party`，也可以用环境变量覆盖。
