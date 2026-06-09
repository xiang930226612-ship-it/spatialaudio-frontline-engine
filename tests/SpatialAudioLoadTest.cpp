#include <windows.h>
#include <stddef.h>

struct lua_State;
using lua_CFunction = int (*)(lua_State*);
using PFN_lua_createtable = void (*)(lua_State*, int, int);
using PFN_lua_pushcclosure = void (*)(lua_State*, lua_CFunction, int);
using PFN_lua_setfield = void (*)(lua_State*, int, const char*);
using PFN_lua_pushstring = const char* (*)(lua_State*, const char*);
static PFN_lua_createtable p_lua_createtable;
static PFN_lua_pushcclosure p_lua_pushcclosure;
static PFN_lua_setfield p_lua_setfield;
static PFN_lua_pushstring p_lua_pushstring;

static bool resolve_lua() {
    HMODULE h = GetModuleHandleA("lua54.dll");
    if (!h) h = LoadLibraryA("lua54.dll");
    if (!h) return false;
    p_lua_createtable = (PFN_lua_createtable)GetProcAddress(h, "lua_createtable");
    p_lua_pushcclosure = (PFN_lua_pushcclosure)GetProcAddress(h, "lua_pushcclosure");
    p_lua_setfield = (PFN_lua_setfield)GetProcAddress(h, "lua_setfield");
    p_lua_pushstring = (PFN_lua_pushstring)GetProcAddress(h, "lua_pushstring");
    return p_lua_createtable && p_lua_pushcclosure && p_lua_setfield && p_lua_pushstring;
}

static int sa_ping(lua_State* L) {
    p_lua_pushstring(L, "SpatialAudioLoadTest:x86:ok");
    return 1;
}

extern "C" __declspec(dllexport) int luaopen_SpatialAudioLoadTest(lua_State* L) {
    if (!resolve_lua()) return 0;
    p_lua_createtable(L, 0, 1);
    p_lua_pushcclosure(L, sa_ping, 0);
    p_lua_setfield(L, -2, "ping");
    return 1;
}
