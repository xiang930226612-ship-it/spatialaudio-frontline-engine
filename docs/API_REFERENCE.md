# API 说明

## Lua API

Lua 侧推荐只通过 `SpatialAudioAdapter.lua` 调用，不直接碰 DLL。

### isReady

```lua
local ok = spatialAudio.isReady()
```

返回空间音频是否初始化并且播放设备可用。

### setListener

```lua
spatialAudio.setListener(playerX, playerY)
```

当前适配层主要使用固定 listener，在玩家本地原点。

### update

```lua
spatialAudio.update(dt)
```

每帧调用一次。当前 C++ 内部会借这个机会清理已结束声音和消费命令队列。

### playOnce

```lua
local ok = spatialAudio.playOnce(path, x, y, gain, minDistance, maxDistance, priority)
```

参数：

- `path`：sound key，例如 `navigation/beep`、`combat/buildings/crystalidle`；
- `x, y`：声音相对玩家的位置，Lua 里 y 会传给 C++ 的 z；
- `gain`：音量倍率；
- `minDistance`：近距离范围；
- `maxDistance`：最大可听范围；
- `priority`：优先级，声源超限时高优先级更容易保留。

返回：

- true：新引擎接管成功；
- false：失败，调用方可走旧音频 fallback。

### playNamed

```lua
local ok = spatialAudio.playNamed(name, path, loop, x, y, gain, minDistance, maxDistance, priority)
```

用于持续音/循环音。`name` 是唯一名字，例如：

```lua
"crystal_idle_" .. tostring(id)
```

### setNamedPosition

```lua
spatialAudio.setNamedPosition(name, x, y)
```

更新 named source 的相对位置。

### setNamedGain

```lua
spatialAudio.setNamedGain(name, gain)
```

更新 named source 的音量。

### releaseNamed

```lua
spatialAudio.releaseNamed(name)
```

停止并释放 named source。

### shutdown

```lua
spatialAudio.shutdown()
```

退出战斗/退出客户端时调用。

## DLL Lua module API

`SpatialAudio.dll` 作为 Lua C module 被加载，公开入口：

```text
luaopen_SpatialAudio
```

Lua adapter 内部加载后可调用底层函数：

```lua
spatial.init(root, csv, sampleRate, maxSources, moduleId)
spatial.shutdown()
spatial.update(dt)
spatial.ready()
spatial.playbackReady()
spatial.lastError()
spatial.setListenerPosition(x, y, z)
spatial.setListenerOrientation(fx, fy, fz, ux, uy, uz)
spatial.setFrontBackEnhancement(rearLowpass, rearGain)
spatial.setEventFrontBackEnhancement(eventKey, rearLowpass, rearGain)
spatial.playOnce3D(eventKey, x, y, z, gain, minDistance, maxDistance, priority)
spatial.playNamed3D(name, eventKey, loop, x, y, z, gain, minDistance, maxDistance, priority)
spatial.setNamedPosition(name, x, y, z)
spatial.setNamedGain(name, gain)
spatial.stopNamed(name)
spatial.releaseNamed(name)
spatial.getNamedState(name)
```

一般项目不要直接调用这些底层接口，统一走 `SpatialAudioAdapter.lua`，方便以后调音和兼容。

## C++ 内部 API

`src/SpatialAudio.h` 声明了 `SF_Audio_*`。当前默认不导出给外部 DLL 调用。

如果以后你自己的工程需要 C++ 直接调用，可以：

1. 改 `SpatialAudio.h` 的 `SF_AUDIO_API` 为 `__declspec(dllexport)`；
2. 重新编译；
3. 用 `GetProcAddress` 或 import lib 调用；
4. 自己负责初始化、update、shutdown 生命周期。

但对外给别人用时建议保持 Lua-only 导出。
