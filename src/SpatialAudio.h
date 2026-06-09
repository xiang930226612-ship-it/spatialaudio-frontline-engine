#pragma once

#ifdef _WIN32
  // Module-only build: do not export the plain C API from SpatialAudio.dll.
  // The DLL is intended to be loaded only as a Lua module through luaopen_SpatialAudio.
  // The SF_Audio_* functions remain callable inside this DLL by the Lua wrapper below,
  // but GetProcAddress("SF_Audio_...") will not expose them to outside callers.
  #define SF_AUDIO_API extern "C"
#else
  #define SF_AUDIO_API extern "C"
#endif

SF_AUDIO_API int  SF_Audio_Init(const char* projectRootUtf8, const char* csvPathUtf8, int sampleRate, int maxSources);
SF_AUDIO_API int  SF_Audio_InitForModule(const char* projectRootUtf8, const char* csvPathUtf8, int sampleRate, int maxSources, const char* moduleIdUtf8);
SF_AUDIO_API void SF_Audio_Shutdown(void);
SF_AUDIO_API void SF_Audio_Update(float dtSeconds);
SF_AUDIO_API int  SF_Audio_IsReady(void);
SF_AUDIO_API int  SF_Audio_IsPlaybackReady(void);
SF_AUDIO_API const char* SF_Audio_GetLastError(void);
SF_AUDIO_API void SF_Audio_SetListenerPosition(float x, float y, float z);
SF_AUDIO_API void SF_Audio_SetListenerOrientation(float fx, float fy, float fz, float ux, float uy, float uz);
SF_AUDIO_API void SF_Audio_SetFrontBackEnhancement(float rearLowpass, float rearGain);
SF_AUDIO_API void SF_Audio_SetEventFrontBackEnhancement(const char* eventKeyUtf8, float rearLowpass, float rearGain);
SF_AUDIO_API unsigned int SF_Audio_PlayOnce3D(const char* eventKeyUtf8, float x, float y, float z, float gain, float minDistance, float maxDistance, int priority);
SF_AUDIO_API unsigned int SF_Audio_PlayNamed3D(const char* nameUtf8, const char* eventKeyUtf8, int loop, float x, float y, float z, float gain, float minDistance, float maxDistance, int priority);
SF_AUDIO_API void SF_Audio_SetNamedPosition(const char* nameUtf8, float x, float y, float z);
SF_AUDIO_API void SF_Audio_SetNamedGain(const char* nameUtf8, float gain);
SF_AUDIO_API void SF_Audio_StopNamed(const char* nameUtf8);
SF_AUDIO_API void SF_Audio_ReleaseNamed(const char* nameUtf8);
SF_AUDIO_API int  SF_Audio_GetNamedState(const char* nameUtf8);


