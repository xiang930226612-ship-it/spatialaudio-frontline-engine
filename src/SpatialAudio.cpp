#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "SpatialAudio.h"

#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdio>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

#include "phonon.h"

// Enable miniaudio's Vorbis/Ogg decoding path when stb_vorbis is available.
// The project uses .ogg entries in frontline.csv; without this, those 3D events
// fall back to the old engine. stb_vorbis is a third-party dependency, not Game
// project code.
#if defined(__has_include)
#  if __has_include("stb_vorbis.c")
#    include "stb_vorbis.c"
     // stb_vorbis uses short preprocessor names internally; remove them before
     // miniaudio and this file's Lua wrapper are compiled as C++.
#    ifdef L
#      undef L
#    endif
#    ifdef C
#      undef C
#    endif
#    ifdef R
#      undef R
#    endif
#  endif
#endif

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

struct SourceState {
    unsigned int handle = 0;
    std::string key;
    std::shared_ptr<const std::vector<float>> pcmMono;
    size_t cursor = 0;
    bool loop = false;
    float x = 0, y = 0, z = 0;
    float gain = 1;
    float minDistance = 1;
    float maxDistance = 30;
    int priority = 0;
    int state = 2; // 0 playing, 2 stopped, 4 invalid
    float rearLowpassState = 0.0f;
    float rearLowpass = -1.0f;
    float rearGain = -1.0f;
    IPLBinauralEffect effect = nullptr;
};

static std::mutex g_mutex; // init/csv/cache control mutex; audio callback does not take this during playback
static std::mutex g_cmdMutex;
static std::mutex g_errorMutex;
static bool g_ready = false;
static bool g_playbackReady = false;
static std::string g_root;
static std::string g_lastError;
static thread_local std::string g_lastErrorSnapshot;
static std::map<std::string, std::string> g_eventToFile;
static std::map<std::string, SourceState> g_named;
static std::vector<SourceState> g_once;
static unsigned int g_nextHandle = 1;
static int g_sampleRate = 48000;
static int g_frameSize = 512;
static int g_maxSources = 64;
static float g_listener[3] = {0,0,0};
static float g_forward[3] = {0,0,1};
static float g_up[3] = {0,1,0};
static float g_rearLowpass = 0.0f;
static float g_rearGain = 1.0f;
static float g_distanceRolloffPower = 0.8f;
struct EventFrontBackTuning { float rearLowpass = -1.0f; float rearGain = -1.0f; };
static std::map<std::string, EventFrontBackTuning> g_eventFrontBack;
static std::map<std::string, std::shared_ptr<const std::vector<float>>> g_pcmCache; // event key -> shared decoded mono PCM cache
static unsigned long long g_limitDrops = 0;
static unsigned long long g_limitEvictions = 0;
static ma_device g_device;
static bool g_deviceInit = false;
static volatile bool g_shuttingDown = false;
static IPLContext g_iplContext = nullptr;
static IPLHRTF g_hrtf = nullptr;
static IPLAudioSettings g_audioSettings{};
static std::vector<float> g_mixMono;
static std::vector<float> g_mixLeft;
static std::vector<float> g_mixRight;

enum class AudioCommandType { Play, SetNamedPosition, SetNamedGain, StopNamed, ReleaseNamed, SetListenerPosition, SetListenerOrientation, SetFrontBack, SetEventFrontBack, Cleanup };
struct AudioCommand {
    AudioCommandType type = AudioCommandType::Cleanup;
    std::string name;
    SourceState source;
    float a=0,b=0,c=0,d=0,e=0,f=0;
    EventFrontBackTuning eventTuning;
};
static std::deque<AudioCommand> g_commands;
static unsigned long long g_cmdDrops = 0;
static constexpr size_t kMaxQueuedCommands = 4096;

static void setLastError(const std::string& message) { std::lock_guard<std::mutex> lock(g_errorMutex); g_lastError = message; }
static void clearLastError() { std::lock_guard<std::mutex> lock(g_errorMutex); g_lastError.clear(); }
static bool ensureMixBuffersNoLock() {
    size_t n = (size_t)std::max(1, g_frameSize);
    try { g_mixMono.assign(n, 0.0f); g_mixLeft.assign(n, 0.0f); g_mixRight.assign(n, 0.0f); }
    catch(...) { setLastError("mix buffer allocation failed"); return false; }
    return true;
}

static std::string trim(std::string s) {
    auto notSpace = [](unsigned char ch){ return !std::isspace(ch); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}
static bool startsWith(const std::string& s, const char* prefix) { std::string p(prefix); return s.size() >= p.size() && s.compare(0, p.size(), p) == 0; }
static bool fileExists(const std::string& p) { DWORD attr = GetFileAttributesA(p.c_str()); return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY); }
static std::string joinPath(std::string a, std::string b) { if (a.empty()) return b; char c=a[a.size()-1]; return (c=='\\'||c=='/') ? a+b : a+"\\"+b; }
static bool isAbsPath(const std::string& p) { return p.size() >= 2 && p[1] == ':'; }
static std::string fullPathName(const std::string& p) {
    char buf[MAX_PATH]; DWORD n = GetFullPathNameA(p.c_str(), MAX_PATH, buf, nullptr);
    if(n == 0 || n >= MAX_PATH) return {};
    return std::string(buf);
}
static std::string lowerAscii(std::string s) { for(char& c : s) c=(char)std::tolower((unsigned char)c); return s; }
static bool canonicalAudioPath(const std::string& rel, std::string& out) {
    if(rel.empty() || isAbsPath(rel) || rel.find("..") != std::string::npos) return false;
    std::string base = fullPathName(joinPath(g_root, "audio\\frontline"));
    std::string full = fullPathName(joinPath(base, rel));
    if(base.empty() || full.empty()) return false;
    if(base.back() != '\\' && base.back() != '/') base.push_back('\\');
    std::string lb=lowerAscii(base), lf=lowerAscii(full);
    if(lf.compare(0, lb.size(), lb) != 0) return false;
    out = full;
    return true;
}
static std::string extractSourcePath(const std::string& source) { size_t p=source.find("path="); if(p==std::string::npos) return {}; p+=5; size_t e=source.find('|',p); return trim(source.substr(p, e==std::string::npos ? std::string::npos : e-p)); }
static std::vector<std::string> parseCsvLine(const std::string& line) {
    std::vector<std::string> out; std::string cur; bool quoted=false;
    for(size_t i=0;i<line.size();++i){ char ch=line[i]; if(ch=='"'){ if(quoted && i+1<line.size() && line[i+1]=='"'){cur.push_back('"');++i;} else quoted=!quoted; } else if(ch==',' && !quoted){ out.push_back(cur); cur.clear(); } else cur.push_back(ch); }
    out.push_back(cur); return out;
}
static bool loadCsv(const std::string& csvPath) {
    g_eventToFile.clear(); std::ifstream in(csvPath.c_str(), std::ios::binary); if(!in){ setLastError("cannot open csv: "+csvPath); return false; }
    std::string line; if(!std::getline(in,line)){ setLastError("empty csv"); return false; }
    auto header=parseCsvLine(line); int folderIdx=-1,eventIdx=-1,sourceIdx=-1;
    for(int i=0;i<(int)header.size();++i){ std::string h=trim(header[i]); if(h=="Folder") folderIdx=i; if(h=="Event") eventIdx=i; if(h=="Source") sourceIdx=i; }
    if(folderIdx<0 || eventIdx<0 || sourceIdx<0){ setLastError("csv missing Folder/Event/Source"); return false; }
    while(std::getline(in,line)){
        auto row=parseCsvLine(line); int maxIdx=folderIdx>eventIdx?folderIdx:eventIdx; maxIdx=maxIdx>sourceIdx?maxIdx:sourceIdx; if((int)row.size()<=maxIdx) continue;
        std::string folder=trim(row[folderIdx]); std::string event=trim(row[eventIdx]); if(folder.empty()||event.empty()) continue;
        while(!folder.empty() && (folder.back()=='/' || folder.back()=='\\')) folder.pop_back(); if(startsWith(folder,"frontline/")) folder=folder.substr(10);
        std::string rel=extractSourcePath(row[sourceIdx]); if(rel.empty()) continue; std::replace(rel.begin(), rel.end(), '/', '\\');
        std::string full; if(!canonicalAudioPath(rel, full)) { setLastError("unsafe audio path in csv: "+rel); return false; }
        g_eventToFile[folder+"/"+event]=full;
    }
    if(g_eventToFile.empty()){ setLastError("csv resolved zero audio events"); return false; } return true;
}
static bool resolveKeyNoLock(const char* key, std::string& pathOut) {
    if(!key || !*key){ setLastError("empty event key"); return false; }
    auto it=g_eventToFile.find(key); if(it==g_eventToFile.end()){ setLastError(std::string("event key not found: ")+key); return false; }
    if(!fileExists(it->second)){ setLastError(std::string("audio file missing: ")+it->second); return false; }
    pathOut=it->second; return true;
}
static bool decodeMonoFile(const std::string& path, std::vector<float>& out) {
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 1, (ma_uint32)g_sampleRate);
    ma_uint64 frames = 0; void* data = nullptr;
    ma_result r = ma_decode_file(path.c_str(), &cfg, &frames, &data);
    if(r != MA_SUCCESS || !data || frames == 0){ setLastError("decode failed: " + path); if(data) ma_free(data, nullptr); return false; }
    out.assign((float*)data, (float*)data + (size_t)frames);
    ma_free(data, nullptr); return true;
}
// Returns shared decoded PCM from memory after the first decode for a given event key.
// Each SourceState keeps only a shared_ptr, so repeated plays do not copy the full PCM buffer.
static bool getCachedPcmForKey(const std::string& key, const std::string& path, std::shared_ptr<const std::vector<float>>& out) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto cached = g_pcmCache.find(key);
        if(cached != g_pcmCache.end()) { out = cached->second; return true; }
    }
    std::vector<float> decoded;
    if(!decodeMonoFile(path, decoded)) return false;
    auto decodedPtr = std::make_shared<const std::vector<float>>(std::move(decoded));
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        auto existing = g_pcmCache.find(key);
        if(existing != g_pcmCache.end()) { out = existing->second; return true; }
        g_pcmCache[key] = decodedPtr;
    }
    out = decodedPtr;
    return true;
}
static void releaseSource(SourceState& s) { if(s.effect) iplBinauralEffectRelease(&s.effect); s.effect=nullptr; }
static bool createEffect(SourceState& s) {
    if(!g_iplContext || !g_hrtf) return false;
    IPLBinauralEffectSettings settings{}; settings.hrtf = g_hrtf;
    if(iplBinauralEffectCreate(g_iplContext, &g_audioSettings, &settings, &s.effect) != IPL_STATUS_SUCCESS){ s.effect=nullptr; return false; }
    return true;
}
static IPLVector3 sourceDirection(const SourceState& s) {
    IPLVector3 src{ s.x, s.y, -s.z }; // Lua boundary uses +Z front; Steam Audio uses -Z ahead.
    IPLVector3 listener{ g_listener[0], g_listener[1], -g_listener[2] };
    IPLVector3 ahead{ g_forward[0], g_forward[1], -g_forward[2] };
    IPLVector3 up{ g_up[0], g_up[1], g_up[2] };
    if(g_iplContext) return iplCalculateRelativeDirection(g_iplContext, src, listener, ahead, up);
    float dx=src.x-listener.x, dy=src.y-listener.y, dz=src.z-listener.z; float len=std::sqrt(dx*dx+dy*dy+dz*dz); if(len<0.0001f) return IPLVector3{0,0,-1}; return IPLVector3{dx/len,dy/len,dz/len};
}
static float distanceGain(const SourceState& s) {
    float dx=s.x-g_listener[0], dy=s.y-g_listener[1], dz=s.z-g_listener[2];
    float d=std::sqrt(dx*dx+dy*dy+dz*dz);
    float minD=std::max(0.0f, s.minDistance), maxD=std::max(minD, s.maxDistance);
    if(maxD <= minD + 0.0001f) return 1.0f;
    if(d <= minD) return 1.0f;
    if(d >= maxD) return 0.0f;
    float normalized = 1.0f - ((d - minD) / (maxD - minD));
    float power = std::max(0.1f, g_distanceRolloffPower);
    return std::pow(std::max(0.0f, std::min(1.0f, normalized)), power);
}
static float rearAmountNoLock(const SourceState& s) {
    // Plane-only front/back cue. Lua boundary uses X/Z plane, +Z is listener front.
    // Return 0 for front/side, up to 1 for directly behind. No height/up-down cue is introduced.
    float dx = s.x - g_listener[0];
    float dz = s.z - g_listener[2];
    float len = std::sqrt(dx*dx + dz*dz);
    if(len < 0.0001f) return 0.0f;
    float fx = g_forward[0];
    float fz = g_forward[2];
    float flen = std::sqrt(fx*fx + fz*fz);
    if(flen < 0.0001f) { fx = 0.0f; fz = 1.0f; flen = 1.0f; }
    float dot = (dx/len) * (fx/flen) + (dz/len) * (fz/flen);
    return std::max(0.0f, std::min(1.0f, -dot));
}
static void applyFrontBackEnhancement(SourceState& s, float* samples, ma_uint32 n) {
    float rear = rearAmountNoLock(s);
    float sourceLowpass = (s.rearLowpass >= 0.0f) ? s.rearLowpass : g_rearLowpass;
    float sourceRearGain = (s.rearGain >= 0.0f) ? s.rearGain : g_rearGain;
    float lowpassMix = std::max(0.0f, std::min(1.0f, sourceLowpass)) * rear;
    float rearGain = std::max(0.0f, std::min(2.0f, sourceRearGain));
    float gain = 1.0f + (rearGain - 1.0f) * rear;
    if(lowpassMix <= 0.0001f && std::abs(gain - 1.0f) <= 0.0001f) {
        if(n > 0) s.rearLowpassState = samples[n-1];
        return;
    }
    // Fixed one-pole low-pass used only as a rear timbre cue. Blending keeps it subtle.
    const float alpha = 0.075f;
    float state = s.rearLowpassState;
    for(ma_uint32 i=0;i<n;++i){
        float sample = samples[i];
        state += alpha * (sample - state);
        float filtered = sample + (state - sample) * lowpassMix;
        samples[i] = filtered * gain;
    }
    s.rearLowpassState = state;
}
static void mixSource(SourceState& s, float* out, ma_uint32 frameCount, std::vector<float>& mono, std::vector<float>& left, std::vector<float>& right) {
    if(s.state != 0 || !s.pcmMono || s.pcmMono->empty()) return;
    const std::vector<float>& pcm = *s.pcmMono;
    ma_uint32 offset=0;
    while(offset < frameCount && s.state == 0){
        ma_uint32 n = (ma_uint32)std::min<size_t>(g_frameSize, frameCount-offset);
        std::fill(mono.begin(), mono.begin()+n, 0.0f); std::fill(left.begin(), left.begin()+n, 0.0f); std::fill(right.begin(), right.begin()+n, 0.0f);
        for(ma_uint32 i=0;i<n;++i){
            if(s.cursor >= pcm.size()){ if(s.loop) s.cursor=0; else { s.state=2; break; } }
            mono[i] = pcm[s.cursor++] * s.gain * distanceGain(s);
        }
        applyFrontBackEnhancement(s, mono.data(), n);
        if(s.effect && g_iplContext){
            float* inData[1] = { mono.data() }; float* outData[2] = { left.data(), right.data() };
            IPLAudioBuffer inBuf{1, (IPLint32)n, inData}; IPLAudioBuffer outBuf{2, (IPLint32)n, outData};
            IPLBinauralEffectParams params{}; params.direction=sourceDirection(s); params.interpolation=IPL_HRTFINTERPOLATION_BILINEAR; params.spatialBlend=1.0f; params.hrtf=g_hrtf; params.peakDelays=nullptr;
            iplBinauralEffectApply(s.effect, &params, &inBuf, &outBuf);
        } else {
            float pan = std::max(-1.0f, std::min(1.0f, s.x / 20.0f)); float l=std::sqrt((1.0f-pan)*0.5f), r=std::sqrt((1.0f+pan)*0.5f);
            for(ma_uint32 i=0;i<n;++i){ left[i]=mono[i]*l; right[i]=mono[i]*r; }
        }
        for(ma_uint32 i=0;i<n;++i){ out[(offset+i)*2+0] += left[i]; out[(offset+i)*2+1] += right[i]; }
        offset += n;
    }
}
static void cleanupInactiveNoLock();
static void processQueuedCommandsNoLock();
static void dataCallback(ma_device* device, void* output, const void* input, ma_uint32 frameCount) {
    (void)device; (void)input; float* out=(float*)output; std::fill(out, out + frameCount*2, 0.0f);
    if(g_shuttingDown) return;
    processQueuedCommandsNoLock();
    cleanupInactiveNoLock();
    if(g_mixMono.empty() || g_mixLeft.empty() || g_mixRight.empty()) return;
    for(auto& s: g_once) mixSource(s, out, frameCount, g_mixMono, g_mixLeft, g_mixRight);
    for(auto& kv: g_named) mixSource(kv.second, out, frameCount, g_mixMono, g_mixLeft, g_mixRight);
    for(ma_uint32 i=0;i<frameCount*2;++i) out[i]=std::max(-1.0f, std::min(1.0f, out[i]));
}
static bool initSteamAudio() {
    IPLContextSettings cs{}; cs.version = STEAMAUDIO_VERSION; cs.simdLevel = IPL_SIMDLEVEL_SSE2; cs.flags = IPL_CONTEXTFLAGS_VALIDATION;
    if(iplContextCreate(&cs, &g_iplContext) != IPL_STATUS_SUCCESS){ setLastError("SteamAudio context create failed"); return false; }
    g_audioSettings.samplingRate = g_sampleRate; g_audioSettings.frameSize = g_frameSize;
    IPLHRTFSettings hs{}; hs.type=IPL_HRTFTYPE_DEFAULT; hs.volume=1.0f; hs.normType=IPL_HRTFNORMTYPE_NONE;
    if(iplHRTFCreate(g_iplContext, &g_audioSettings, &hs, &g_hrtf) != IPL_STATUS_SUCCESS){ setLastError("SteamAudio HRTF create failed"); return false; }
    return true;
}
static bool initDevice() {
    g_shuttingDown = false;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32; cfg.playback.channels = 2; cfg.sampleRate = (ma_uint32)g_sampleRate; cfg.periodSizeInFrames = (ma_uint32)g_frameSize; cfg.dataCallback = dataCallback;
    if(ma_device_init(nullptr, &cfg, &g_device) != MA_SUCCESS){ setLastError("miniaudio device init failed"); return false; }
    g_deviceInit = true;
    if(ma_device_start(&g_device) != MA_SUCCESS){ setLastError("miniaudio device start failed"); ma_device_uninit(&g_device); g_deviceInit=false; return false; }
    return true;
}
static void shutdownAudioNoLock(){
    g_shuttingDown = true;
    if(g_deviceInit){ ma_device_stop(&g_device); ma_device_uninit(&g_device); g_deviceInit=false; }
    for(auto& s:g_once) releaseSource(s); g_once.clear(); for(auto& kv:g_named) releaseSource(kv.second); g_named.clear(); { std::lock_guard<std::mutex> cmdLock(g_cmdMutex); for(auto& c:g_commands) releaseSource(c.source); g_commands.clear(); } g_pcmCache.clear();
    if(g_hrtf) iplHRTFRelease(&g_hrtf); if(g_iplContext) iplContextRelease(&g_iplContext); g_hrtf=nullptr; g_iplContext=nullptr; g_playbackReady=false;
}
static void cleanupInactiveNoLock() {
    for(auto it=g_once.begin(); it!=g_once.end(); ){ if(it->state!=0){ releaseSource(*it); it=g_once.erase(it); } else ++it; }
    for(auto it=g_named.begin(); it!=g_named.end(); ){ if(it->second.state==4 || it->second.state==2){ releaseSource(it->second); it=g_named.erase(it); } else ++it; }
}
static void applyEventFrontBackTuningNoLock(SourceState& s) {
    auto it = g_eventFrontBack.find(s.key);
    if(it != g_eventFrontBack.end()){
        s.rearLowpass = it->second.rearLowpass;
        s.rearGain = it->second.rearGain;
    }
}
static int activeNamedCountNoLock() {
    int n = 0;
    for(const auto& kv : g_named) if(kv.second.state == 0) ++n;
    return n;
}
static float sourceImportanceNoLock(const SourceState& s) {
    return (float)s.priority * 1000.0f + distanceGain(s) * std::max(0.0f, s.gain) * 100.0f;
}
static bool enforceOneShotLimitNoLock(const SourceState& incoming) {
    int namedActive = activeNamedCountNoLock();
    int onceLimit = std::max(0, g_maxSources - namedActive);
    if(onceLimit <= 0) { ++g_limitDrops; return false; }
    if((int)g_once.size() < onceLimit) return true;
    if(g_once.empty()) { ++g_limitDrops; return false; }
    auto victim = g_once.begin();
    float victimScore = sourceImportanceNoLock(*victim);
    for(auto it = g_once.begin() + 1; it != g_once.end(); ++it) {
        float score = sourceImportanceNoLock(*it);
        if(score < victimScore) { victim = it; victimScore = score; }
    }
    float incomingScore = sourceImportanceNoLock(incoming);
    if(incomingScore <= victimScore) { ++g_limitDrops; return false; }
    releaseSource(*victim);
    g_once.erase(victim);
    ++g_limitEvictions;
    return true;
}
static bool reserveNamedSlotNoLock(const char* name) {
    if(!name || !*name) return true;
    if(g_named.find(name) != g_named.end()) return true;
    int totalActive = activeNamedCountNoLock() + (int)g_once.size();
    if(totalActive < g_maxSources) return true;
    if(!g_once.empty()) {
        auto victim = g_once.begin();
        float victimScore = sourceImportanceNoLock(*victim);
        for(auto it = g_once.begin() + 1; it != g_once.end(); ++it) {
            float score = sourceImportanceNoLock(*it);
            if(score < victimScore) { victim = it; victimScore = score; }
        }
        releaseSource(*victim);
        g_once.erase(victim);
        ++g_limitEvictions;
        return true;
    }
    ++g_limitDrops;
    return false;
}
static void processCommandNoLock(AudioCommand& cmd) {
    switch(cmd.type) {
    case AudioCommandType::Play:
        if(!cmd.name.empty()){
            if(!reserveNamedSlotNoLock(cmd.name.c_str())) { releaseSource(cmd.source); return; }
            auto old=g_named.find(cmd.name); if(old!=g_named.end()) releaseSource(old->second);
            g_named[cmd.name]=std::move(cmd.source);
        } else {
            if(!enforceOneShotLimitNoLock(cmd.source)) { releaseSource(cmd.source); return; }
            g_once.push_back(std::move(cmd.source));
        }
        break;
    case AudioCommandType::SetNamedPosition: {
        auto it=g_named.find(cmd.name); if(it!=g_named.end()){ it->second.x=cmd.a; it->second.y=cmd.b; it->second.z=cmd.c; }
        break;
    }
    case AudioCommandType::SetNamedGain: {
        auto it=g_named.find(cmd.name); if(it!=g_named.end()) it->second.gain=cmd.a;
        break;
    }
    case AudioCommandType::StopNamed: {
        auto it=g_named.find(cmd.name); if(it!=g_named.end()) it->second.state=2;
        break;
    }
    case AudioCommandType::ReleaseNamed: {
        auto it=g_named.find(cmd.name); if(it!=g_named.end()){ releaseSource(it->second); g_named.erase(it); }
        break;
    }
    case AudioCommandType::SetListenerPosition:
        g_listener[0]=cmd.a; g_listener[1]=cmd.b; g_listener[2]=cmd.c; break;
    case AudioCommandType::SetListenerOrientation:
        g_forward[0]=cmd.a; g_forward[1]=cmd.b; g_forward[2]=cmd.c; g_up[0]=cmd.d; g_up[1]=cmd.e; g_up[2]=cmd.f; break;
    case AudioCommandType::SetFrontBack:
        g_rearLowpass=std::max(0.0f,std::min(1.0f,cmd.a)); g_rearGain=std::max(0.0f,std::min(2.0f,cmd.b)); break;
    case AudioCommandType::SetEventFrontBack:
        if(!cmd.name.empty()) g_eventFrontBack[cmd.name]=cmd.eventTuning; break;
    case AudioCommandType::Cleanup:
        cleanupInactiveNoLock(); break;
    }
}
static void processQueuedCommandsNoLock() {
    std::deque<AudioCommand> local;
    if(g_cmdMutex.try_lock()){
        local.swap(g_commands);
        g_cmdMutex.unlock();
    }
    for(auto& cmd : local) processCommandNoLock(cmd);
}
static bool enqueueCommand(AudioCommand&& cmd) {
    if(g_shuttingDown) return false;
    std::lock_guard<std::mutex> lock(g_cmdMutex);
    if(g_commands.size() >= kMaxQueuedCommands) { ++g_cmdDrops; return false; }
    g_commands.push_back(std::move(cmd));
    return true;
}
static unsigned int enqueueSource(const char* name, SourceState&& s) {
    if(!g_playbackReady){ setLastError("playback not ready"); releaseSource(s); return 0; }
    AudioCommand cmd; cmd.type = AudioCommandType::Play; cmd.name = name ? name : ""; cmd.source = std::move(s);
    unsigned int h = cmd.source.handle;
    if(!enqueueCommand(std::move(cmd))) { setLastError("audio command queue full"); return 0; }
    return h;
}
static unsigned int addSourceFromApi(const char* name, const char* key, bool loop, float x, float y, float z, float gain, float minDistance, float maxDistance, int priority) {
    std::string path;
    SourceState s;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        if(!g_playbackReady){ setLastError("playback not ready"); return 0; }
        if(!resolveKeyNoLock(key, path)) return 0;
        s.handle=g_nextHandle++; s.key=key; s.loop=loop; s.x=x; s.y=y; s.z=z; s.gain=gain; s.minDistance=minDistance; s.maxDistance=maxDistance; s.priority=priority; s.state=0;
        applyEventFrontBackTuningNoLock(s);
    }
    if(!getCachedPcmForKey(s.key, path, s.pcmMono)) return 0;
    createEffect(s);
    return enqueueSource(name, std::move(s));
}

static bool moduleAllowed(const char* moduleIdUtf8) {
    if(!moduleIdUtf8) return false;
    std::string module = moduleIdUtf8;
    std::transform(module.begin(), module.end(), module.begin(), [](unsigned char c){ return (char)std::tolower(c); });
    return module == "frontline";
}

SF_AUDIO_API int SF_Audio_Init(const char* projectRootUtf8, const char* csvPathUtf8, int sampleRate, int maxSources) {
    return SF_Audio_InitForModule(projectRootUtf8, csvPathUtf8, sampleRate, maxSources, "");
}

SF_AUDIO_API int SF_Audio_InitForModule(const char* projectRootUtf8, const char* csvPathUtf8, int sampleRate, int maxSources, const char* moduleIdUtf8) {
    std::lock_guard<std::mutex> lock(g_mutex); shutdownAudioNoLock(); g_ready=false;
    if(!moduleAllowed(moduleIdUtf8)) { setLastError("SteamAudio denied: module is not allowed; expected frontline"); return 0; }
    g_root = projectRootUtf8 && *projectRootUtf8 ? projectRootUtf8 : "."; g_sampleRate = sampleRate > 0 ? sampleRate : 48000; g_maxSources = maxSources > 0 ? maxSources : 64;
    std::string csv = csvPathUtf8 && *csvPathUtf8 ? csvPathUtf8 : joinPath(g_root, "csv\\frontline.csv");
    if(!loadCsv(csv)) return 0; if(!ensureMixBuffersNoLock()) return 0; g_ready=true;
    if(!initSteamAudio()) { shutdownAudioNoLock(); g_ready=false; return 0; }
    if(!initDevice()) { shutdownAudioNoLock(); g_ready=false; return 0; }
    g_playbackReady=true; clearLastError(); return 1;
}
SF_AUDIO_API void SF_Audio_Shutdown(void){ std::lock_guard<std::mutex> lock(g_mutex); shutdownAudioNoLock(); g_eventToFile.clear(); g_ready=false; }
SF_AUDIO_API void SF_Audio_Update(float dtSeconds){ (void)dtSeconds; AudioCommand cmd; cmd.type=AudioCommandType::Cleanup; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API int SF_Audio_IsReady(void){ std::lock_guard<std::mutex> lock(g_mutex); return g_ready?1:0; }
SF_AUDIO_API int SF_Audio_IsPlaybackReady(void){ std::lock_guard<std::mutex> lock(g_mutex); return g_playbackReady?1:0; }
SF_AUDIO_API const char* SF_Audio_GetLastError(void){ std::lock_guard<std::mutex> lock(g_errorMutex); g_lastErrorSnapshot = g_lastError; return g_lastErrorSnapshot.c_str(); }
SF_AUDIO_API void SF_Audio_SetListenerPosition(float x,float y,float z){ AudioCommand cmd; cmd.type=AudioCommandType::SetListenerPosition; cmd.a=x; cmd.b=y; cmd.c=z; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API void SF_Audio_SetListenerOrientation(float fx,float fy,float fz,float ux,float uy,float uz){ AudioCommand cmd; cmd.type=AudioCommandType::SetListenerOrientation; cmd.a=fx; cmd.b=fy; cmd.c=fz; cmd.d=ux; cmd.e=uy; cmd.f=uz; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API void SF_Audio_SetFrontBackEnhancement(float rearLowpass,float rearGain){ AudioCommand cmd; cmd.type=AudioCommandType::SetFrontBack; cmd.a=rearLowpass; cmd.b=rearGain; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API void SF_Audio_SetEventFrontBackEnhancement(const char* eventKeyUtf8,float rearLowpass,float rearGain){ if(!eventKeyUtf8 || !*eventKeyUtf8) return; EventFrontBackTuning t; t.rearLowpass=std::max(0.0f,std::min(1.0f,rearLowpass)); t.rearGain=std::max(0.0f,std::min(2.0f,rearGain)); { std::lock_guard<std::mutex> lock(g_mutex); g_eventFrontBack[eventKeyUtf8]=t; } AudioCommand cmd; cmd.type=AudioCommandType::SetEventFrontBack; cmd.name=eventKeyUtf8; cmd.eventTuning=t; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API unsigned int SF_Audio_PlayOnce3D(const char* eventKeyUtf8,float x,float y,float z,float gain,float minDistance,float maxDistance,int priority){ return addSourceFromApi(nullptr,eventKeyUtf8,false,x,y,z,gain,minDistance,maxDistance,priority); }
SF_AUDIO_API unsigned int SF_Audio_PlayNamed3D(const char* nameUtf8,const char* eventKeyUtf8,int loop,float x,float y,float z,float gain,float minDistance,float maxDistance,int priority){ return addSourceFromApi(nameUtf8,eventKeyUtf8,loop!=0,x,y,z,gain,minDistance,maxDistance,priority); }
SF_AUDIO_API void SF_Audio_SetNamedPosition(const char* nameUtf8,float x,float y,float z){ if(!nameUtf8 || !*nameUtf8) return; AudioCommand cmd; cmd.type=AudioCommandType::SetNamedPosition; cmd.name=nameUtf8; cmd.a=x; cmd.b=y; cmd.c=z; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API void SF_Audio_SetNamedGain(const char* nameUtf8,float gain){ if(!nameUtf8 || !*nameUtf8) return; AudioCommand cmd; cmd.type=AudioCommandType::SetNamedGain; cmd.name=nameUtf8; cmd.a=gain; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API void SF_Audio_StopNamed(const char* nameUtf8){ if(!nameUtf8 || !*nameUtf8) return; AudioCommand cmd; cmd.type=AudioCommandType::StopNamed; cmd.name=nameUtf8; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API void SF_Audio_ReleaseNamed(const char* nameUtf8){ if(!nameUtf8 || !*nameUtf8) return; AudioCommand cmd; cmd.type=AudioCommandType::ReleaseNamed; cmd.name=nameUtf8; enqueueCommand(std::move(cmd)); }
SF_AUDIO_API int SF_Audio_GetNamedState(const char* nameUtf8){ (void)nameUtf8; return g_playbackReady ? 0 : 4; }

// Optional Lua module wrapper. Uses GetProcAddress so no lua54.lib/lua headers are required.
struct lua_State;
using lua_CFunction = int (*)(lua_State*);
using PFN_lua_createtable = void (*)(lua_State*, int, int);
using PFN_lua_pushcclosure = void (*)(lua_State*, lua_CFunction, int);
using PFN_lua_setfield = void (*)(lua_State*, int, const char*);
using PFN_lua_pushboolean = void (*)(lua_State*, int);
using PFN_lua_pushinteger = void (*)(lua_State*, long long);
using PFN_lua_pushstring = const char* (*)(lua_State*, const char*);
using PFN_lua_tolstring = const char* (*)(lua_State*, int, size_t*);
using PFN_lua_tonumberx = double (*)(lua_State*, int, int*);
using PFN_lua_tointegerx = long long (*)(lua_State*, int, int*);
static PFN_lua_createtable p_lua_createtable; static PFN_lua_pushcclosure p_lua_pushcclosure; static PFN_lua_setfield p_lua_setfield; static PFN_lua_pushboolean p_lua_pushboolean; static PFN_lua_pushinteger p_lua_pushinteger; static PFN_lua_pushstring p_lua_pushstring; static PFN_lua_tolstring p_lua_tolstring; static PFN_lua_tonumberx p_lua_tonumberx; static PFN_lua_tointegerx p_lua_tointegerx;
static bool resolve_lua_api(){ HMODULE h=GetModuleHandleA("lua54.dll"); if(!h) h=LoadLibraryA("lua54.dll"); if(!h) return false; p_lua_createtable=(PFN_lua_createtable)GetProcAddress(h,"lua_createtable"); p_lua_pushcclosure=(PFN_lua_pushcclosure)GetProcAddress(h,"lua_pushcclosure"); p_lua_setfield=(PFN_lua_setfield)GetProcAddress(h,"lua_setfield"); p_lua_pushboolean=(PFN_lua_pushboolean)GetProcAddress(h,"lua_pushboolean"); p_lua_pushinteger=(PFN_lua_pushinteger)GetProcAddress(h,"lua_pushinteger"); p_lua_pushstring=(PFN_lua_pushstring)GetProcAddress(h,"lua_pushstring"); p_lua_tolstring=(PFN_lua_tolstring)GetProcAddress(h,"lua_tolstring"); p_lua_tonumberx=(PFN_lua_tonumberx)GetProcAddress(h,"lua_tonumberx"); p_lua_tointegerx=(PFN_lua_tointegerx)GetProcAddress(h,"lua_tointegerx"); return p_lua_createtable&&p_lua_pushcclosure&&p_lua_setfield&&p_lua_pushboolean&&p_lua_pushinteger&&p_lua_pushstring&&p_lua_tolstring&&p_lua_tonumberx&&p_lua_tointegerx; }
static const char* L_str(lua_State* L,int i,const char* d=""){ size_t n=0; const char* s=p_lua_tolstring?p_lua_tolstring(L,i,&n):nullptr; return s?s:d; }
static float L_num(lua_State* L,int i,float d=0){ int ok=0; double v=p_lua_tonumberx?p_lua_tonumberx(L,i,&ok):0; return ok?(float)v:d; }
static int L_int(lua_State* L,int i,int d=0){ int ok=0; long long v=p_lua_tointegerx?p_lua_tointegerx(L,i,&ok):0; return ok?(int)v:d; }
static int L_init(lua_State* L){ p_lua_pushboolean(L,SF_Audio_InitForModule(L_str(L,1),L_str(L,2),L_int(L,3,48000),L_int(L,4,64),L_str(L,5,""))); return 1; }
static int L_shutdown(lua_State* L){ (void)L; SF_Audio_Shutdown(); return 0; }
static int L_update(lua_State* L){ SF_Audio_Update(L_num(L,1,0)); return 0; }
static int L_ready(lua_State* L){ p_lua_pushboolean(L,SF_Audio_IsReady()); return 1; }
static int L_playback_ready(lua_State* L){ p_lua_pushboolean(L,SF_Audio_IsPlaybackReady()); return 1; }
static int L_err(lua_State* L){ p_lua_pushstring(L,SF_Audio_GetLastError()); return 1; }
static int L_listener_pos(lua_State* L){ SF_Audio_SetListenerPosition(L_num(L,1),L_num(L,2),L_num(L,3)); return 0; }
static int L_listener_ori(lua_State* L){ SF_Audio_SetListenerOrientation(L_num(L,1,0),L_num(L,2,0),L_num(L,3,1),L_num(L,4,0),L_num(L,5,1),L_num(L,6,0)); return 0; }
static int L_front_back(lua_State* L){ SF_Audio_SetFrontBackEnhancement(L_num(L,1,0),L_num(L,2,1)); return 0; }
static int L_event_front_back(lua_State* L){ SF_Audio_SetEventFrontBackEnhancement(L_str(L,1),L_num(L,2,0),L_num(L,3,1)); return 0; }
static int L_play_once(lua_State* L){ unsigned int h=SF_Audio_PlayOnce3D(L_str(L,1),L_num(L,2),L_num(L,3),L_num(L,4),L_num(L,5,1),L_num(L,6,1),L_num(L,7,30),L_int(L,8,0)); p_lua_pushinteger(L,h); return 1; }
static int L_play_named(lua_State* L){ unsigned int h=SF_Audio_PlayNamed3D(L_str(L,1),L_str(L,2),L_int(L,3,0),L_num(L,4),L_num(L,5),L_num(L,6),L_num(L,7,1),L_num(L,8,1),L_num(L,9,30),L_int(L,10,0)); p_lua_pushinteger(L,h); return 1; }
static int L_set_named_pos(lua_State* L){ SF_Audio_SetNamedPosition(L_str(L,1),L_num(L,2),L_num(L,3),L_num(L,4)); return 0; }
static int L_set_named_gain(lua_State* L){ SF_Audio_SetNamedGain(L_str(L,1),L_num(L,2,1)); return 0; }
static int L_release_named(lua_State* L){ SF_Audio_ReleaseNamed(L_str(L,1)); return 0; }
static int L_named_state(lua_State* L){ p_lua_pushinteger(L,SF_Audio_GetNamedState(L_str(L,1))); return 1; }
static void setfunc(lua_State* L,const char* name,lua_CFunction f){ p_lua_pushcclosure(L,f,0); p_lua_setfield(L,-2,name); }
extern "C" __declspec(dllexport) int luaopen_SpatialAudio(lua_State* L){ if(!resolve_lua_api()) return 0; p_lua_createtable(L,0,16); setfunc(L,"init",L_init); setfunc(L,"shutdown",L_shutdown); setfunc(L,"update",L_update); setfunc(L,"isReady",L_ready); setfunc(L,"isPlaybackReady",L_playback_ready); setfunc(L,"lastError",L_err); setfunc(L,"setListenerPosition",L_listener_pos); setfunc(L,"setListenerOrientation",L_listener_ori); setfunc(L,"setFrontBackEnhancement",L_front_back); setfunc(L,"setEventFrontBackEnhancement",L_event_front_back); setfunc(L,"playOnce3D",L_play_once); setfunc(L,"playNamed3D",L_play_named); setfunc(L,"setNamedPosition",L_set_named_pos); setfunc(L,"setNamedGain",L_set_named_gain); setfunc(L,"releaseNamed",L_release_named); setfunc(L,"getNamedState",L_named_state); return 1; }





#ifdef _WIN32
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved) {
    (void)hModule;
    (void)reserved;
    if (reason == DLL_PROCESS_DETACH) {
        g_shuttingDown = true;
        if (g_mutex.try_lock()) {
            shutdownAudioNoLock();
            g_mutex.unlock();
        } else if (g_deviceInit) {
            ma_device_stop(&g_device);
            ma_device_uninit(&g_device);
            g_deviceInit = false;
        }
    }
    return TRUE;
}
#endif


