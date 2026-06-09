# 从源码编译

## 环境要求

- Windows；
- Visual Studio 2022 Build Tools 或 Visual Studio 2022 Community；
- MSVC x86 工具链；
- PowerShell；
- 仓库内已包含：
  - `third_party/steamaudio`
  - `third_party/miniaudio/miniaudio.h`
  - `third_party/stb_vorbis/stb_vorbis.c`

## 一键构建

```powershell
cd D:\spatialaudio-frontline-engine
.\scripts\build_spatial_audio.ps1
```

默认输出：

```text
runtime/libc/SpatialAudio.dll
runtime/libc/phonon.dll
```

## 指定输出目录

比如直接输出到你的开发项目：

```powershell
.\scripts\build_spatial_audio.ps1 -OutputDir "C:\sfdeveloper-05-15\libc"
```

## 第三方依赖查找顺序

脚本默认用仓库内：

```text
third_party/steamaudio
third_party/miniaudio
third_party/stb_vorbis
```

也可以用环境变量覆盖：

```powershell
$env:STEAMAUDIO_SDK_DIR="C:\Game\steamaudio_4.8.1\steamaudio"
$env:MINIAUDIO_DIR="C:\Game\third_party\miniaudio"
$env:STB_VORBIS_DIR="C:\Game\third_party\stb_vorbis"
.\scripts\build_spatial_audio.ps1
```

## 为什么是 x86

当前目标客户端是 32 位，所以构建脚本使用：

```text
vcvarsall.bat x86
/MACHINE:X86
SteamAudio lib/windows-x86/phonon.lib
```

如果以后客户端变成 64 位，需要同步改：

- vcvarsall 参数：`x64`；
- SteamAudio lib 路径：`lib/windows-x64`；
- 输出 DLL 和客户端位数一致；
- 重新验证 Lua 加载。

## 默认导出策略

当前版本默认只导出：

```text
luaopen_SpatialAudio
```

`SF_Audio_*` 函数默认不作为 DLL 外部 C API 导出。这样别人拿到 DLL 不容易直接泛用，只能按 Lua 模块方式接。

如果以后你自己的项目确实要 C/C++ 直接调用，可以修改 `src/SpatialAudio.h`，把 Windows 下的 `SF_AUDIO_API` 改回：

```cpp
#define SF_AUDIO_API extern "C" __declspec(dllexport)
```

然后重新编译。但给别人包时建议保持当前默认。

## 验证构建结果

构建后至少检查：

```powershell
Get-Item .\runtime\libc\SpatialAudio.dll
Get-Item .\runtime\libc\phonon.dll
```

如果有 dumpbin，可以检查导出：

```powershell
dumpbin /exports .\runtime\libc\SpatialAudio.dll
```

期望只看到 `luaopen_SpatialAudio` 这个公开 Lua 入口。
