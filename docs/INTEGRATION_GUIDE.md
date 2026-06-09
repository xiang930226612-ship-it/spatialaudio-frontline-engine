# 项目接入说明

下面以目标项目根目录为 `C:\sfdeveloper-05-15` 举例。其他项目同理。

## 1. 复制运行时

```text
runtime/libc/SpatialAudio.dll -> 目标项目/libc/SpatialAudio.dll
runtime/libc/phonon.dll       -> 目标项目/libc/phonon.dll
```

也可以直接执行：

```powershell
.\scripts\install_to_project.ps1 -TargetRoot "C:\sfdeveloper-05-15"
```

## 2. 复制 Lua 适配层

```text
lua/resources/script/module/frontline/SpatialAudioAdapter.lua
  -> 目标项目/resources/script/module/frontline/SpatialAudioAdapter.lua

lua/resources/script/module/frontline/SpatialAudioTuning.lua
  -> 目标项目/resources/script/module/frontline/SpatialAudioTuning.lua
```

如果目标项目有 server 镜像，也同步：

```text
lua/server/frontline/client/SpatialAudioAdapter.lua
  -> 目标项目/server/frontline/client/SpatialAudioAdapter.lua

lua/server/frontline/client/SpatialAudioTuning.lua
  -> 目标项目/server/frontline/client/SpatialAudioTuning.lua
```

## 3. 复制导航音效

```text
assets/audio/frontline/navigation/beep.wav
  -> 目标项目/audio/frontline/navigation/beep.wav
```

注意不是：

```text
resources/audio/...
```

DLL 解析路径是：

```text
目标项目/audio/frontline/navigation/beep.wav
```

## 4. 合并 CSV

参考表：

```text
assets/csv/frontline.csv
```

如果目标项目资源表和当前完全一致，可以覆盖：

```text
目标项目/csv/frontline.csv
```

如果目标项目已有自己的修改，不要覆盖，至少合并导航 beep 行：

```csv
73,beep,frontline/navigation,navigation,frontline,FALSE,,,,,,,type=single|path=navigation/beep.wav
```

Lua 调用 key：

```lua
navigation/beep
```

内部解析到：

```text
audio/frontline/navigation/beep.wav
```

## 5. 合并 ClientMain.lua

参考文件：

```text
lua/resources/script/module/frontline/ClientMain.reference.lua
lua/server/frontline/client/ClientMain.reference.lua
```

不要盲目覆盖生产项目，除非确认目标项目和参考版完全一致。

关键接入点如下。

### 5.1 加载 SpatialAudioAdapter

```lua
local spatialAudio = nil
local spatialAudioLoadTried = false
local function getSpatialAudio()
  if spatialAudioLoadTried then return spatialAudio end
  spatialAudioLoadTried = true
  local loaderPaths = {
    "resources/script/module/frontline/SpatialAudioAdapter.lua",
    "./resources/script/module/frontline/SpatialAudioAdapter.lua",
  }
  for _, loaderPath in ipairs(loaderPaths) do
    local okLoad, chunk = pcall(loadfile, loaderPath)
    if okLoad and type(chunk) == "function" then
      local okRun, mod = pcall(chunk)
      if okRun and type(mod) == "table" then
        spatialAudio = mod
        return spatialAudio
      end
    end
  end
  return spatialAudio
end
```

### 5.2 设置监听器

```lua
local function updateAudioListener()
  local sa = getSpatialAudio()
  if sa then sa.setListener(0, 0) end
end
```

当前方案使用固定前方：

```lua
listenerForward = { x = 0, y = 0, z = 1 }
listenerUp      = { x = 0, y = 1, z = 0 }
```

### 5.3 世界坐标转玩家相对坐标

传给空间音频的坐标应该是“声音相对玩家”的坐标。

```lua
local function audioRelativePosition(x, y)
  local p = myPlayer and myPlayer() or nil
  if not p then return {x = x or 0, y = 0, z = y or 0} end
  return {
    x = (x or 0) - (p.x or 0),
    y = 0,
    z = (y or 0) - (p.y or 0),
  }
end
```

### 5.4 播放一次性 3D 音效

```lua
local function play3d(path, worldX, worldY, gain, minDistance, maxDistance, priority)
  local sa = getSpatialAudio()
  if not sa then return false end
  local pos = audioRelativePosition(worldX, worldY)
  return sa.playOnce(path, pos.x, pos.z, gain or 1, minDistance or 1, maxDistance or 30, priority or 10)
end

play3d("navigation/beep", x, y, 1.0, 2, 30, 20)
```

### 5.5 播放持续/循环 3D 音效

适合水晶塔持续音、建筑持续音等。

```lua
local function startLoop(name, path, worldX, worldY)
  local sa = getSpatialAudio()
  if not sa then return false end
  local pos = audioRelativePosition(worldX, worldY)
  return sa.playNamed(name, path, true, pos.x, pos.z, 1.0, 1, 30, 20)
end

local function updateLoop(name, worldX, worldY, gain)
  local sa = getSpatialAudio()
  if not sa then return end
  local pos = audioRelativePosition(worldX, worldY)
  sa.setNamedPosition(name, pos.x, pos.z)
  sa.setNamedGain(name, gain or 1)
end

local function stopLoop(name)
  local sa = getSpatialAudio()
  if sa then sa.releaseNamed(name) end
end
```

### 5.6 每帧更新

在 `sf_update(ds)` 或同类 tick 里：

```lua
local sa = getSpatialAudio()
if sa then
  sa.update(ds or 0)
  sa.setListener(0, 0)
end
```

### 5.7 退出清理

```lua
local sa = getSpatialAudio()
if sa then sa.shutdown() end
```

## 6. 独立客户端必须处理 ClientMain.lc

如果目标客户端优先加载 `.lc`，必须把合并后的 `ClientMain.lua` 编译/转换成：

```text
resources/script/module/frontline/ClientMain.lc
```

否则新引擎在编辑器里生效，独立客户端不生效。

## 7. 日志验证

运行后看：

```text
目标项目/logs/SpatialAudioAdapter.runtime.log
```

正常会有：

```text
SpatialAudio ready; sound3d routed to SteamAudio DLL
SpatialAudio tuning axisSwap=false, invertX=false, invertY=false, gainScale=1.0, rearLowpass=0.0, rearGain=1.0
```

导航 beep 播放时会有类似：

```text
navigation/beep SteamAudio playOnce ... err=
```

`err=` 为空一般表示没有错误。
