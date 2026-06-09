# 常见问题排查

## 编辑器生效，独立客户端不生效

最常见原因：独立客户端优先加载旧的：

```text
resources/script/module/frontline/ClientMain.lc
```

解决：把合并后的 `ClientMain.lua` 重新编译/转换成 `ClientMain.lc`，并更新 manifest/MD5。

## SpatialAudio DLL 加载失败

检查：

```text
目标项目/libc/SpatialAudio.dll
目标项目/libc/phonon.dll
```

两者必须都存在，并且位数和客户端一致。当前是 x86/32 位。

## init failed: module is not allowed

当前源码白名单只允许：

```text
frontline
```

检查 Lua adapter：

```lua
local MODULE_ID = "frontline"
```

新项目要改 C++ `moduleAllowed` 并重新编译。

## sound key 播放失败

检查 `csv/frontline.csv` 是否有对应 key，以及最后字段是否有：

```text
path=xxx.wav
```

比如导航 beep：

```csv
73,beep,frontline/navigation,navigation,frontline,FALSE,,,,,,,type=single|path=navigation/beep.wav
```

Lua key 是：

```lua
navigation/beep
```

实际文件：

```text
audio/frontline/navigation/beep.wav
```

## 左右反了

改：

```lua
invertX = true
```

## 前后反了

改：

```lua
invertY = true
```

## X/Y 轴混了

改：

```lua
axisSwap = true
```

## 偶发卡顿

先看：

```text
logs/SpatialAudioAdapter.runtime.log
```

重点排查：

- 是否第一次播放才解码；
- 是否同一帧创建太多声源；
- 是否 named source 没有复用，而是反复 release/play；
- 是否日志被刷爆；
- 是否音频文件太大或格式异常。

当前 C++ 已经避免音频线程抢主锁短静音，但首次 IO/解码仍可能有成本。必要时做预热。

## 没有任何声音

检查：

1. Windows 默认输出设备；
2. 客户端是否静音；
3. `phonon.dll` 是否能加载；
4. `SpatialAudioAdapter.runtime.log`；
5. `csv/frontline.csv`；
6. 音频实际文件；
7. sample rate 是否 48000。
