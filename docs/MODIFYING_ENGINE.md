# 怎么修改到别的项目

## 1. 改模块白名单

当前源码只允许：

```cpp
return module == "frontline";
```

位置在 `src/SpatialAudio.cpp` 的 `moduleAllowed`。

如果新项目模块名叫 `battle`，可以改成：

```cpp
return module == "frontline" || module == "battle";
```

然后 Lua adapter 里改：

```lua
local MODULE_ID = "battle"
```

## 2. 改音频根目录

当前 DLL 安全限制是只允许解析到：

```text
项目根目录/audio/frontline/...
```

核心位置：

```cpp
std::string base = fullPathName(joinPath(g_root, "audio\\frontline"));
```

如果别的项目音频根目录是：

```text
audio/battle/...
```

就改成：

```cpp
std::string base = fullPathName(joinPath(g_root, "audio\\battle"));
```

同时 CSV 的 folder/path 要对应。

## 3. 改 CSV 文件名

Lua adapter 初始化时传：

```lua
local csv = root .. "/csv/frontline.csv"
spatial.init(root, csv, 48000, 64, MODULE_ID)
```

如果新项目用 `battle.csv`，改成：

```lua
local csv = root .. "/csv/battle.csv"
```

## 4. 改 sound key 规则

当前推荐外部只传逻辑 key：

```lua
navigation/beep
combat/buildings/crystalidle
```

不要直接传绝对路径。这样可以避免别人拿 DLL 随便播放任意文件，也方便统一管理资源。

CSV 行里关键是最后字段：

```text
path=navigation/beep.wav
```

DLL 会用这个相对路径到音频根目录下找文件。

## 5. 改最大声源数

Lua adapter 初始化：

```lua
spatial.init(root, csv, 48000, 64, MODULE_ID)
```

`64` 是最大声源数。一般不建议太高。声源超限时，C++ 会按优先级、距离衰减、gain 做保留。

如果某项目音效很多，可以尝试：

```lua
spatial.init(root, csv, 48000, 96, MODULE_ID)
```

但要听是否有 CPU 压力。

## 6. 改前后/左右听感

优先改 Lua，不要改 C++：

```text
lua/resources/script/module/frontline/SpatialAudioTuning.lua
```

常用参数：

```lua
invertX = false      -- 左右反了就切 true
invertY = false      -- 前后反了就切 true
axisSwap = false     -- X/Y 轴混了就切 true
xScale = 1.0
yScale = 1.0
gainScale = 1.0
rearLowpass = 0.0
rearGain = 1.0
```

如果只是“前后不明显”，可以小幅试：

```lua
rearLowpass = 0.2
rearGain = 0.95
```

但当前版本默认保持中性：

```lua
rearLowpass = 0.0
rearGain = 1.0
```

## 7. 增加新音效

步骤：

1. 把音频文件放到项目音频目录，例如：

```text
audio/frontline/navigation/newbeep.wav
```

2. 在 CSV 里加一行，最后字段包含：

```text
path=navigation/newbeep.wav
```

3. Lua 里用 key 播放：

```lua
spatialAudio.playOnce("navigation/newbeep", x, y, 1, 2, 30, 20)
```

4. 如果独立客户端有资源打包/manifest，记得把 wav 和 csv/lc 都打进去。

## 8. 打开普通 C API 导出

默认不建议。确实需要时改 `SpatialAudio.h`：

```cpp
#define SF_AUDIO_API extern "C" __declspec(dllexport)
```

然后重新编译。这样外部程序可以直接 `GetProcAddress("SF_Audio_PlayOnce3D")`。

如果是给别人用的保护版，不要这么改。

## 9. 调试卡顿

当前已经用了命令队列和 PCM 共享缓存。如果还有卡顿，按顺序看：

1. 是否第一次播放大 wav/ogg 解码；
2. 是否资源在机械硬盘/网络盘；
3. 是否每帧创建大量新 named source；
4. 是否 update 没有每帧调用；
5. 是否 maxSources 太低导致频繁淘汰/重建；
6. 是否日志每帧刷太多。

可以考虑做预热：进入战斗时先对关键 sound key 做一次静音/极低音量播放，触发解码进缓存。
