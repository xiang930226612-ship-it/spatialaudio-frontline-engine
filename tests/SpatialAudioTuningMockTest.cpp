#include <windows.h>
#include <cstdio>

struct lua_State;
using lua_KContext = long long;
using lua_KFunction = int (*)(lua_State*, int, lua_KContext);
using PFN_luaL_newstate = lua_State* (*)();
using PFN_luaL_openlibs = void (*)(lua_State*);
using PFN_lua_close = void (*)(lua_State*);
using PFN_luaL_loadstring = int (*)(lua_State*, const char*);
using PFN_lua_pcallk = int (*)(lua_State*, int, int, int, lua_KContext, lua_KFunction);
using PFN_lua_tolstring = const char* (*)(lua_State*, int, size_t*);
using PFN_lua_settop = void (*)(lua_State*, int);

static FARPROC sym(HMODULE h, const char* name) {
    FARPROC p = GetProcAddress(h, name);
    if (!p) std::printf("missing lua symbol: %s\n", name);
    return p;
}

int main() {
    HMODULE lua = LoadLibraryA("C:\\sfdeveloper-05-15\\lua54.dll");
    if (!lua) { std::printf("LoadLibrary lua54.dll failed: %lu\n", GetLastError()); return 2; }

    auto luaL_newstate = (PFN_luaL_newstate)sym(lua, "luaL_newstate");
    auto luaL_openlibs = (PFN_luaL_openlibs)sym(lua, "luaL_openlibs");
    auto lua_close = (PFN_lua_close)sym(lua, "lua_close");
    auto luaL_loadstring = (PFN_luaL_loadstring)sym(lua, "luaL_loadstring");
    auto lua_pcallk = (PFN_lua_pcallk)sym(lua, "lua_pcallk");
    auto lua_tolstring = (PFN_lua_tolstring)sym(lua, "lua_tolstring");
    auto lua_settop = (PFN_lua_settop)sym(lua, "lua_settop");
    if (!luaL_newstate || !luaL_openlibs || !lua_close || !luaL_loadstring || !lua_pcallk || !lua_tolstring || !lua_settop) return 3;

    lua_State* L = luaL_newstate();
    if (!L) { std::printf("luaL_newstate failed\n"); return 4; }
    luaL_openlibs(L);

    const char* script = R"LUA(
package.path = 'C:/sfdeveloper-05-15/resources/script/module/frontline/?.lua;' .. package.path
package.cpath = 'C:/sfdeveloper-05-15/libc/?.dll;' .. package.cpath

local calls = {}
local function approx(a, b, label)
  assert(type(a) == 'number', label .. ' not number: ' .. tostring(a))
  assert(math.abs(a - b) < 0.0001, label .. ' expected ' .. tostring(b) .. ' got ' .. tostring(a))
end

package.preload['SpatialAudioTuning'] = function()
  return {
    axisSwap = true,
    invertX = true,
    invertY = false,
    xScale = 2,
    yScale = 3,
    gainScale = 4,
    minDistance = 5,
    maxDistance = 50,
    listenerForward = { x = 1, y = 0, z = 0 },
    listenerUp = { x = 0, y = 1, z = 0 },
    rearLowpass = 0.35,
    rearGain = 0.92,
    eventFrontBack = { ["combat/buildings/crystalidle"] = { rearLowpass = 0.58, rearGain = 0.86 } },
  }
end

package.preload['SpatialAudio'] = function()
  return {
    init = function(root, csv, rate, buffer)
      calls.init = { root, csv, rate, buffer }
      return true
    end,
    isPlaybackReady = function() return true end,
    isReady = function() return true end,
    lastError = function() return '' end,
    setListenerPosition = function(x, y, z) calls.listenerPosition = { x, y, z } end,
    setListenerOrientation = function(fx, fy, fz, ux, uy, uz) calls.listenerOrientation = { fx, fy, fz, ux, uy, uz } end,
    setFrontBackEnhancement = function(rearLowpass, rearGain) calls.frontBack = { rearLowpass, rearGain } end,
    setEventFrontBackEnhancement = function(key, rearLowpass, rearGain) calls.eventFrontBack = { key, rearLowpass, rearGain } end,
    playOnce3D = function(path, x, y, z, gain, minD, maxD, priority)
      calls.playOnce = { path = path, x = x, y = y, z = z, gain = gain, minD = minD, maxD = maxD, priority = priority }
      return 101
    end,
    playNamed3D = function(name, path, loop, x, y, z, gain, minD, maxD, priority)
      calls.playNamed = { name = name, path = path, loop = loop, x = x, y = y, z = z, gain = gain, minD = minD, maxD = maxD, priority = priority }
      return 202
    end,
    setNamedPosition = function(name, x, y, z) calls.namedPosition = { name = name, x = x, y = y, z = z } end,
    setNamedGain = function(name, gain) calls.namedGain = { name = name, gain = gain } end,
    releaseNamed = function(name) calls.releaseNamed = name end,
    update = function(dt) calls.update = dt end,
    shutdown = function() calls.shutdown = true end,
  }
end

local adapter = require('SpatialAudioAdapter')
assert(adapter.isReady() == true, 'adapter should become ready with mocked SpatialAudio')
assert(calls.init and calls.init[3] == 48000 and calls.init[4] == 64, 'init args not forwarded')
assert(calls.frontBack, 'front/back enhancement not forwarded')
approx(calls.frontBack[1], 0.35, 'rearLowpass')
approx(calls.frontBack[2], 0.92, 'rearGain')
assert(calls.eventFrontBack and calls.eventFrontBack[1] == 'combat/buildings/crystalidle', 'event front/back key')
approx(calls.eventFrontBack[2], 0.58, 'event rearLowpass')
approx(calls.eventFrontBack[3], 0.86, 'event rearGain')

assert(adapter.setListener(1, 2) == true, 'setListener failed')
approx(calls.listenerOrientation[1], 1, 'listener forward x')
approx(calls.listenerOrientation[2], 0, 'listener forward y')
approx(calls.listenerOrientation[3], 0, 'listener forward z')
approx(calls.listenerOrientation[5], 1, 'listener up y')

assert(adapter.playOnce('movement/junglefootstep1', 10, 3, 2, nil, nil, 7) == true, 'playOnce failed')
approx(calls.playOnce.x, -6, 'playOnce x')
approx(calls.playOnce.y, 0, 'playOnce y')
approx(calls.playOnce.z, 30, 'playOnce z')
approx(calls.playOnce.gain, 8, 'playOnce gain')
approx(calls.playOnce.minD, 5, 'playOnce default minDistance')
approx(calls.playOnce.maxD, 50, 'playOnce default maxDistance')
approx(calls.playOnce.priority, 7, 'playOnce priority')

assert(adapter.playNamed('n', 'movement/junglefootstep1', true, 10, 3, 2, 6, 60, 7) == true, 'playNamed failed')
assert(calls.playNamed.name == 'n', 'playNamed name')
assert(calls.playNamed.loop == 1, 'playNamed loop')
approx(calls.playNamed.x, -6, 'playNamed x')
approx(calls.playNamed.z, 30, 'playNamed z')
approx(calls.playNamed.gain, 8, 'playNamed gain')
approx(calls.playNamed.minD, 6, 'playNamed explicit minDistance')
approx(calls.playNamed.maxD, 60, 'playNamed explicit maxDistance')

assert(adapter.setNamedPosition('n', 10, 3) == true, 'setNamedPosition failed')
approx(calls.namedPosition.x, -6, 'namedPosition x')
approx(calls.namedPosition.y, 0, 'namedPosition y')
approx(calls.namedPosition.z, 30, 'namedPosition z')
assert(calls.namedPosition.name == 'n', 'namedPosition name')

assert(adapter.setNamedGain('n', 2) == true, 'setNamedGain failed')
approx(calls.namedGain.gain, 8, 'namedGain gain')
assert(calls.namedGain.name == 'n', 'namedGain name')

assert(adapter.update(0.25) == true, 'update failed')
approx(calls.update, 0.25, 'update dt')
assert(adapter.releaseNamed('n') == true, 'releaseNamed failed')
assert(calls.releaseNamed == 'n', 'releaseNamed name')
adapter.shutdown()
assert(calls.shutdown == true, 'shutdown not forwarded')

return 'SpatialAudioAdapter tuning mock test OK'
)LUA";

    int rc = luaL_loadstring(L, script);
    if (rc == 0) rc = lua_pcallk(L, 0, 1, 0, 0, nullptr);
    if (rc != 0) {
        size_t n = 0; const char* msg = lua_tolstring(L, -1, &n);
        std::printf("SpatialAudio tuning mock test failed: %s\n", msg ? msg : "(no message)");
        lua_close(L);
        return 5;
    }
    size_t n = 0; const char* msg = lua_tolstring(L, -1, &n);
    std::printf("%s\n", msg ? msg : "SpatialAudioAdapter tuning mock test OK");
    lua_settop(L, 0);
    lua_close(L);
    return 0;
}
