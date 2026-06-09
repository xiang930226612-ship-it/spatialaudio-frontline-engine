local M = {}

local spatial = nil
local initialized = false
local usable = false
local nextRetryAt = 0
local retryDelay = 2.0
local logged = {}

local function fileExists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function normalizePath(path)
  return tostring(path or ""):gsub("\\", "/")
end

local function detectRoot()
  local candidates = {}
  local function add(path)
    path = normalizePath(path)
    if path ~= "" then candidates[#candidates + 1] = path end
  end

  if debug and debug.getinfo then
    local info = debug.getinfo(1, "S")
    local src = info and info.source or nil
    if type(src) == "string" and src:sub(1, 1) == "@" then
      src = normalizePath(src:sub(2))
      local marker = "/resources/script/module/frontline/SpatialAudioAdapter.lua"
      local lowerSrc = string.lower(src)
      local lowerMarker = string.lower(marker)
      local at = lowerSrc:find(lowerMarker, 1, true)
      if at then add(src:sub(1, at - 1)) end
    end
  end

  add(".")
  add("C:/Program Files (x86)/Test")
  add("C:/sfdeveloper-05-15")

  for _, candidate in ipairs(candidates) do
    if fileExists(candidate .. "/libc/SpatialAudio.dll") or fileExists(candidate .. "/csv/frontline.csv") then
      return candidate
    end
  end
  return candidates[1] or "C:/sfdeveloper-05-15"
end

local MODULE_ID = "frontline"
local root = detectRoot()
local csv = root .. "/csv/frontline.csv"
local logPath = root .. "/logs/SpatialAudioAdapter.runtime.log"

local tuning = {
  invertX = false,
  invertY = false,
  axisSwap = false,
  xScale = 1.0,
  yScale = 1.0,
  gainScale = 1.0,
  minDistance = 1.0,
  maxDistance = 30.0,
  listenerForward = { x = 0.0, y = 0.0, z = 1.0 },
  listenerUp = { x = 0.0, y = 1.0, z = 0.0 },
  rearLowpass = 0.35,
  rearGain = 0.92,
  eventFrontBack = {},
}

local function numberOr(value, fallback)
  if type(value) == "number" then return value end
  return fallback
end

local function boolOr(value, fallback)
  if type(value) == "boolean" then return value end
  return fallback
end

local function vectorOr(value, fallback)
  if type(value) ~= "table" then return fallback end
  return {
    x = numberOr(value.x or value[1], fallback.x),
    y = numberOr(value.y or value[2], fallback.y),
    z = numberOr(value.z or value[3], fallback.z),
  }
end

local function applyTuning(user)
  if type(user) ~= "table" then return end
  tuning.invertX = boolOr(user.invertX, tuning.invertX)
  tuning.invertY = boolOr(user.invertY, tuning.invertY)
  tuning.axisSwap = boolOr(user.axisSwap, tuning.axisSwap)
  tuning.xScale = numberOr(user.xScale, tuning.xScale)
  tuning.yScale = numberOr(user.yScale, tuning.yScale)
  tuning.gainScale = numberOr(user.gainScale, tuning.gainScale)
  tuning.minDistance = numberOr(user.minDistance, tuning.minDistance)
  tuning.maxDistance = numberOr(user.maxDistance, tuning.maxDistance)
  tuning.listenerForward = vectorOr(user.listenerForward, tuning.listenerForward)
  tuning.listenerUp = vectorOr(user.listenerUp, tuning.listenerUp)
  tuning.rearLowpass = numberOr(user.rearLowpass, tuning.rearLowpass)
  tuning.rearGain = numberOr(user.rearGain, tuning.rearGain)
  if type(user.eventFrontBack) == "table" then tuning.eventFrontBack = user.eventFrontBack end
end

local tuningModule = nil
if package and package.preload and type(package.preload["SpatialAudioTuning"]) == "function" then
  local tuningPreloadOk, preloadModule = pcall(package.preload["SpatialAudioTuning"])
  if tuningPreloadOk then tuningModule = preloadModule end
else
  local tuningPath = root .. "/resources/script/module/frontline/SpatialAudioTuning.lua"
  local tuningOk, tuningChunk = pcall(loadfile, tuningPath)
  if tuningOk and type(tuningChunk) == "function" then
    local tuningRunOk, loadedModule = pcall(tuningChunk)
    if tuningRunOk then tuningModule = loadedModule end
  end
end
applyTuning(tuningModule)

local function tunedPosition(x, y)
  local tx = numberOr(x, 0)
  local ty = numberOr(y, 0)
  if tuning.axisSwap then tx, ty = ty, tx end
  if tuning.invertX then tx = -tx end
  if tuning.invertY then ty = -ty end
  return tx * tuning.xScale, ty * tuning.yScale
end

local function tunedGain(gain)
  return numberOr(gain, 1) * tuning.gainScale
end

local function now()
  if os and os.clock then return os.clock() end
  return 0
end

local function logOnce(key, text)
  if logged[key] then return end
  logged[key] = true
  local ok, f = pcall(io.open, logPath, "a")
  if ok and f then
    f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    f:close()
  end
end

local function logEvery(key, text)
  local t = now()
  local last = logged[key] or -9999
  if t - last < 10 then return end
  logged[key] = t
  local ok, f = pcall(io.open, logPath, "a")
  if ok and f then
    f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", text, "\n")
    f:close()
  end
end

local function safeCall(fn, ...)
  if not fn then return false end
  local ok, result = pcall(fn, ...)
  if not ok then return false end
  return result
end

local function lastError()
  if spatial and spatial.lastError then
    local ok, msg = pcall(spatial.lastError)
    if ok and msg then return tostring(msg) end
  end
  return ""
end

local function ensureLoaded()
  if usable then return true end
  local t = now()
  if t < nextRetryAt then return false end
  nextRetryAt = t + retryDelay

  package.cpath = root .. "\\libc\\?.dll;" .. "libc\\?.dll;.\\libc\\?.dll;" .. (package.cpath or "")
  if not spatial then
    local ok, mod = false, nil
    if package and package.preload and type(package.preload["SpatialAudio"]) == "function" then
      ok, mod = pcall(package.preload["SpatialAudio"])
    elseif package and package.loadlib then
      local dllPath1 = root .. "\\libc\\SpatialAudio.dll"
      local dllPath2 = root .. "/libc/SpatialAudio.dll"
      local loadOk, loader, err1 = pcall(package.loadlib, dllPath1, "luaopen_SpatialAudio")
      if (not loadOk) or type(loader) ~= "function" then
        local firstErr = tostring(loader) .. " " .. tostring(err1)
        loadOk, loader, err1 = pcall(package.loadlib, dllPath2, "luaopen_SpatialAudio")
        if (not loadOk) or type(loader) ~= "function" then
          logEvery("loadlib_failed", "SpatialAudio package.loadlib failed; path1=" .. dllPath1 .. "; err1=" .. firstErr .. "; path2=" .. dllPath2 .. "; err2=" .. tostring(loader) .. " " .. tostring(err1))
        end
      end
      if loadOk and type(loader) == "function" then ok, mod = pcall(loader) end
    end
    if not ok or not mod then
      logEvery("require_failed", "SpatialAudio DLL load failed; 3D will fall back to nativeapi; mod=" .. tostring(mod))
      return false
    end
    spatial = mod
  end

  if not initialized then
    initialized = safeCall(spatial.init, root, csv, 48000, 64, MODULE_ID) and true or false
    if not initialized then
      logEvery("init_failed", "SpatialAudio init failed; 3D fallback active; " .. lastError())
      return false
    end
  end

  if spatial.isPlaybackReady then
    usable = safeCall(spatial.isPlaybackReady) and true or false
  else
    usable = false
  end

  if usable then
    if spatial.setFrontBackEnhancement then
      safeCall(spatial.setFrontBackEnhancement, tuning.rearLowpass, tuning.rearGain)
    end
    if spatial.setEventFrontBackEnhancement and type(tuning.eventFrontBack) == "table" then
      for key, value in pairs(tuning.eventFrontBack) do
        if type(key) == "string" and type(value) == "table" then
          safeCall(spatial.setEventFrontBackEnhancement, key, numberOr(value.rearLowpass, tuning.rearLowpass), numberOr(value.rearGain, tuning.rearGain))
        end
      end
    end
    logOnce("ready", "SpatialAudio ready; sound3d routed to SteamAudio DLL")
    logOnce("tuning", "SpatialAudio tuning axisSwap=" .. tostring(tuning.axisSwap) .. ", invertX=" .. tostring(tuning.invertX) .. ", invertY=" .. tostring(tuning.invertY) .. ", gainScale=" .. tostring(tuning.gainScale) .. ", rearLowpass=" .. tostring(tuning.rearLowpass) .. ", rearGain=" .. tostring(tuning.rearGain))
  else
    logEvery("playback_not_ready", "SpatialAudio playback not ready; 3D fallback active; " .. lastError())
  end
  return usable
end

function M.isReady()
  return ensureLoaded()
end

function M.setListener(playerX, playerY)
  if not ensureLoaded() then return false end
  safeCall(spatial.setListenerPosition, 0, 0, 0)
  local f = tuning.listenerForward
  local u = tuning.listenerUp
  safeCall(spatial.setListenerOrientation, f.x, f.y, f.z, u.x, u.y, u.z)
  return true
end

function M.update(dt)
  if not ensureLoaded() then return false end
  safeCall(spatial.update, dt or 0)
  return true
end

function M.playOnce(path, x, y, gain, minDistance, maxDistance, priority)
  if not ensureLoaded() then return false end
  local tx, ty = tunedPosition(x, y)
  local finalGain = tunedGain(gain)
  local finalMin = minDistance or tuning.minDistance
  local finalMax = maxDistance or tuning.maxDistance
  local h = safeCall(spatial.playOnce3D, path, tx, 0, ty, finalGain, finalMin, finalMax, priority or 0)
  if path == "navigation/beep" then
    logEvery("nav_once", "navigation/beep SteamAudio playOnce raw=(" .. tostring(x) .. "," .. tostring(y) .. "), tuned=(" .. tostring(tx) .. "," .. tostring(ty) .. "), gain=" .. tostring(finalGain) .. ", range=" .. tostring(finalMin) .. "-" .. tostring(finalMax) .. ", handle=" .. tostring(h) .. ", err=" .. lastError())
  end
  return type(h) == "number" and h ~= 0
end

function M.playNamed(name, path, loop, x, y, gain, minDistance, maxDistance, priority)
  if not ensureLoaded() then return false end
  local tx, ty = tunedPosition(x, y)
  local finalGain = tunedGain(gain)
  local finalMin = minDistance or tuning.minDistance
  local finalMax = maxDistance or tuning.maxDistance
  local h = safeCall(spatial.playNamed3D, name, path, loop and 1 or 0, tx, 0, ty, finalGain, finalMin, finalMax, priority or 0)
  if path == "navigation/beep" then
    logEvery("nav_play", "navigation/beep SteamAudio playNamed name=" .. tostring(name) .. ", raw=(" .. tostring(x) .. "," .. tostring(y) .. "), tuned=(" .. tostring(tx) .. "," .. tostring(ty) .. "), gain=" .. tostring(finalGain) .. ", range=" .. tostring(finalMin) .. "-" .. tostring(finalMax) .. ", handle=" .. tostring(h) .. ", err=" .. lastError())
  end
  return type(h) == "number" and h ~= 0
end

function M.setNamedPosition(name, x, y)
  if not ensureLoaded() then return false end
  local tx, ty = tunedPosition(x, y)
  if name == "frontline_navigation_target" then
    logEvery("nav_setpos", "navigation/beep SteamAudio setNamedPosition raw=(" .. tostring(x) .. "," .. tostring(y) .. "), tuned=(" .. tostring(tx) .. "," .. tostring(ty) .. ")")
  end
  safeCall(spatial.setNamedPosition, name, tx, 0, ty)
  return true
end

function M.setNamedGain(name, gain)
  if not ensureLoaded() then return false end
  safeCall(spatial.setNamedGain, name, tunedGain(gain))
  return true
end

function M.releaseNamed(name)
  if not ensureLoaded() then return false end
  safeCall(spatial.releaseNamed, name)
  return true
end

function M.shutdown()
  if spatial and initialized then safeCall(spatial.shutdown) end
  initialized = false
  usable = false
  nextRetryAt = 0
end

return M

