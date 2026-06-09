#include <windows.h>
#include <cstdio>
#include <string>

struct lua_State;
using lua_KContext = long long;
using lua_KFunction = int (*)(lua_State*, int, lua_KContext);
using PFN_luaL_newstate = lua_State* (*)();
using PFN_luaL_openlibs = void (*)(lua_State*);
using PFN_lua_close = void (*)(lua_State*);
using PFN_luaL_loadstring = int (*)(lua_State*, const char*);
using PFN_luaL_loadfilex = int (*)(lua_State*, const char*, const char*);
using PFN_lua_pcallk = int (*)(lua_State*, int, int, int, lua_KContext, lua_KFunction);
using PFN_lua_tolstring = const char* (*)(lua_State*, int, size_t*);
using PFN_lua_settop = void (*)(lua_State*, int);

static FARPROC sym(HMODULE h, const char* name) {
    FARPROC p = GetProcAddress(h, name);
    if (!p) std::printf("missing lua symbol: %s\n", name);
    return p;
}

int main() {
    const char* root = "C:\\sfdeveloper-05-15";
    const char* libc = "C:\\sfdeveloper-05-15\\libc";
    SetDllDirectoryA(root);
    AddDllDirectory(L"C:\\sfdeveloper-05-15\\libc");
    SetDllDirectoryA(libc);

    HMODULE lua = LoadLibraryA("C:\\sfdeveloper-05-15\\lua54.dll");
    if (!lua) { std::printf("LoadLibrary lua54.dll failed: %lu\n", GetLastError()); return 2; }

    auto luaL_newstate = (PFN_luaL_newstate)sym(lua, "luaL_newstate");
    auto luaL_openlibs = (PFN_luaL_openlibs)sym(lua, "luaL_openlibs");
    auto lua_close = (PFN_lua_close)sym(lua, "lua_close");
    auto luaL_loadstring = (PFN_luaL_loadstring)sym(lua, "luaL_loadstring");
    auto luaL_loadfilex = (PFN_luaL_loadfilex)sym(lua, "luaL_loadfilex");
    auto lua_pcallk = (PFN_lua_pcallk)sym(lua, "lua_pcallk");
    auto lua_tolstring = (PFN_lua_tolstring)sym(lua, "lua_tolstring");
    auto lua_settop = (PFN_lua_settop)sym(lua, "lua_settop");
    if (!luaL_newstate || !luaL_openlibs || !lua_close || !luaL_loadstring || !luaL_loadfilex || !lua_pcallk || !lua_tolstring || !lua_settop) return 3;

    lua_State* L = luaL_newstate();
    if (!L) { std::printf("luaL_newstate failed\n"); return 4; }
    luaL_openlibs(L);

    const char* syntaxFiles[] = {
        "C:\\sfdeveloper-05-15\\resources\\script\\module\\frontline\\SpatialAudioAdapter.lua",
        "C:\\sfdeveloper-05-15\\server\\frontline\\client\\SpatialAudioAdapter.lua",
        "C:\\sfdeveloper-05-15\\resources\\script\\module\\frontline\\ClientMain.lua",
        "C:\\sfdeveloper-05-15\\server\\frontline\\client\\ClientMain.lua"
    };
    for (const char* file : syntaxFiles) {
        int loadRc = luaL_loadfilex(L, file, nullptr);
        if (loadRc != 0) {
            size_t n = 0; const char* msg = lua_tolstring(L, -1, &n);
            std::printf("Lua syntax/loadfile failed for %s: %s\n", file, msg ? msg : "(no message)");
            lua_close(L);
            return 6;
        }
        lua_settop(L, 0);
    }

    const char* script =
        "package.cpath = 'C:/sfdeveloper-05-15/libc/?.dll;' .. package.cpath\n"
        "package.path = 'C:/sfdeveloper-05-15/resources/script/module/frontline/?.lua;' .. package.path\n"
        "local spatial = require('SpatialAudio')\n"
        "assert(type(spatial.init) == 'function')\n"
        "assert(type(spatial.isPlaybackReady) == 'function')\n"
        "assert(type(spatial.playOnce3D) == 'function')\n"
        "local denied = spatial.init('C:/sfdeveloper-05-15', 'C:/sfdeveloper-05-15/csv/frontline.csv', 48000, 64, 'othergame')\n"
        "assert(denied == false, 'wrong module should be denied')\n"
        "local ok = spatial.init('C:/sfdeveloper-05-15', 'C:/sfdeveloper-05-15/csv/frontline.csv', 48000, 64, 'frontline')\n"
        "assert(ok == true, spatial.lastError and spatial.lastError() or 'init failed')\n"
        "assert(spatial.isReady() == true, 'not ready after init')\n"
        "spatial.shutdown()\n"
        "package.loaded['SpatialAudio'] = nil\n"
        "local adapter = require('SpatialAudioAdapter')\n"
        "assert(type(adapter.playOnce) == 'function')\n"
        "assert(type(adapter.isReady()) == 'boolean')\n"
        "adapter.shutdown()\n"
        "return 'Lua require SpatialAudio and SpatialAudioAdapter OK'\n";

    int rc = luaL_loadstring(L, script);
    if (rc == 0) rc = lua_pcallk(L, 0, 1, 0, 0, nullptr);
    if (rc != 0) {
        size_t n = 0; const char* msg = lua_tolstring(L, -1, &n);
        std::printf("Lua require test failed: %s\n", msg ? msg : "(no message)");
        lua_close(L);
        return 5;
    }
    size_t n = 0; const char* msg = lua_tolstring(L, -1, &n);
    std::printf("%s\n", msg ? msg : "Lua require SpatialAudio OK");
    lua_settop(L, 0);
    lua_close(L);
    return 0;
}


