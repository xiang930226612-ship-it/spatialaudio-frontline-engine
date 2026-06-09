local api
local selfIndex = 0
local members = {}
local phase = "idle"
local team = nil
local heroes = {}
local heroOrder = {}
local available = {}
local pickCursor = 1
local pickedHero = nil
local battleModes = {}
local modeCursor = 1
local modeHost = 0
local latest = { players = {}, buildings = {}, monsters = {}, shops = {}, items = {} }
local spectatorViewIndex = nil
local leftWinDown = false
local lastSpectatorNotifyIndex = nil
local moveState = { x = 0, y = 0 }
local shopOpen = false
local shopCursor = 1
local targetMode = "all"
local targetCursor = 1
local lockedTarget = nil
local navOn = false
local navNext = 0
local navTarget = nil
local navAudioSpatial = false
local lastMoveSend = 0
local lastTerrainName = nil
local nextFootstepAt = 0
local FOOTSTEP_INTERVAL = 0.22
local FOOTSTEP_BASE_SPEED = 0.2
local footstepOrder = {1,2,3,4}
local footstepOrderIndex = 5
local blockedMoveKey = nil
local confirmedMoveKey = nil
local pendingFootstepKey = nil
local myPlayer
local crystalIdleAudio = {}
local followAudios = {}
local CRYSTAL_IDLE_PATH = "combat/buildings/crystalidle"
local UI_SOUND_BROWSE = "ui/browse"
local UI_SOUND_CONFIRM = "ui/confirm"
local UI_SOUND_BACK = "ui/back"
-- 3D distance falloff: only 2m is full-volume, then use a gentle curved rolloff so every meter changes audibly.
local AUDIO_FULL_VOLUME_RANGE = 2
local AUDIO_MAX_HEAR_RANGE = 30
local AUDIO_DISTANCE_ROLLOFF_POWER = 0.8
local rangedAudioSeq = 0
local NAV_AUDIO_NAME = "frontline_navigation_target"
local NAV_AUDIO_PATH = "navigation/beep"
local NAV_AUDIO_GAIN_SCALE = 0.55
local NAV_MIN_INTERVAL = 0.12
local NAV_MAX_INTERVAL = 1.35

local spatialAudio = nil
local spatialAudioLoadTried = false
local function getSpatialAudio()
  if spatialAudioLoadTried then return spatialAudio end
  spatialAudioLoadTried = true
  local loaderPaths = {
    "resources/script/module/frontline/SpatialAudioAdapter.lua",
    "./resources/script/module/frontline/SpatialAudioAdapter.lua",
    "C:/Program Files (x86)/Test/resources/script/module/frontline/SpatialAudioAdapter.lua",
    "C:/sfdeveloper-05-15/resources/script/module/frontline/SpatialAudioAdapter.lua",
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

local function C(name, fallback)
  if api and api.Constants and api.Constants[name] then return api.Constants[name] end
  return fallback
end

local function speak(text, appended)
  if api and api.speak then api.speak(text, appended or false) end
end

local function audioX(x)
  return x or 0
end

local function audioZ(y)
  return y or 0
end

local function updateAudioListener()
  if spatialAudio then spatialAudio.setListener(0, 0) end
  if not api then return end
  if api.setListenerPosition then
    api.setListenerPosition({x = 0, y = 0, z = 0})
  end
  if api.setListenerForward then
    api.setListenerForward({x = 0, y = 0, z = 1})
  end
  if api.setListenerUp then
    api.setListenerUp({x = 0, y = 1, z = 0})
  end
end

local function audioRelativePosition(x, y)
  local p = myPlayer and myPlayer() or nil
  if not p then return {x = audioX(x), y = 0, z = audioZ(y)} end
  return {
    x = audioX((x or 0) - (p.x or 0)),
    y = 0,
    z = audioZ((y or 0) - (p.y or 0))
  }
end

local function play2D(path)
  if api and api.playOnce and path and path ~= "" then api.playOnce(path) end
end

local function audioDistance(pos)
  local dx = pos and pos.x or 0
  local dz = pos and pos.z or 0
  return math.sqrt(dx * dx + dz * dz)
end

local function audioGainForDistance(distance, fullRange, maxRange)
  distance = math.max(0, distance or 0)
  fullRange = fullRange or AUDIO_FULL_VOLUME_RANGE
  maxRange = maxRange or AUDIO_MAX_HEAR_RANGE
  if distance <= fullRange then return 1 end
  if distance >= maxRange then return 0 end
  local normalized = (maxRange - distance) / (maxRange - fullRange)
  return normalized ^ AUDIO_DISTANCE_ROLLOFF_POWER
end

local function play3D(path, x, y, fullRange, maxRange, gainScale)
  if not (api and path and path ~= "") then return end
  updateAudioListener()
  local pos = audioRelativePosition(x, y)
  local gain = audioGainForDistance(audioDistance(pos), fullRange, maxRange) * (gainScale or 1)
  if gain <= 0 then return end
  local sa = getSpatialAudio()
  if sa and sa.playOnce(path, pos.x, pos.z, gain, fullRange or AUDIO_FULL_VOLUME_RANGE, maxRange or AUDIO_MAX_HEAR_RANGE, 10) then return end
  if api.playOwn and api.setPosition and api.setGain then
    rangedAudioSeq = rangedAudioSeq + 1
    local name = "frontline_ranged_" .. tostring(rangedAudioSeq)
    api.playOwn(name, path, function()
      followAudios[name] = nil
      if api and api.releaseAudio then api.releaseAudio(name) end
    end)
    api.setPosition(name, pos)
    api.setGain(name, gain)
  elseif api.playWithPosition then
    api.playWithPosition(path, pos.x, pos.y, pos.z)
  end
end

local function findFollowAudioTarget(kind, id)
  if kind == "player" then
    for _,p in ipairs(latest.players or {}) do if tostring(p.index) == tostring(id) then return p end end
  elseif kind == "monster" then
    for _,m in ipairs(latest.monsters or {}) do if tostring(m.id) == tostring(id) then return m end end
  elseif kind == "building" or kind == "tower" or kind == "crystal" or kind == "tempTower" or kind == "clone" then
    for _,b in ipairs(latest.buildings or {}) do if tostring(b.id) == tostring(id) then return b end end
  end
  return nil
end

local function releaseFollowAudio(name)
  if spatialAudio then spatialAudio.releaseNamed(name) end
  followAudios[name] = nil
  if api and api.releaseAudio then api.releaseAudio(name) end
end

local function updateFollowAudios()
  if not ((api and api.setPosition and api.setGain) or spatialAudio) then return end
  local t = api and api.time and api.time() or 0
  updateAudioListener()
  for name,info in pairs(followAudios) do
    local target = findFollowAudioTarget(info.kind, info.id)
    if (info.expireAt and t >= info.expireAt) or not target then
      releaseFollowAudio(name)
    else
      local pos = audioRelativePosition(target.x, target.y)
      local gain = audioGainForDistance(audioDistance(pos), info.fullRange, info.maxRange) * (info.gain or 1)
      if gain <= 0 then
        releaseFollowAudio(name)
      else
        if info.spatial then
          if spatialAudio then
            spatialAudio.setNamedPosition(name, pos.x, pos.z)
            spatialAudio.setNamedGain(name, gain)
          end
        elseif api and api.setPosition and api.setGain then
          api.setPosition(name, pos)
          api.setGain(name, gain)
        end
      end
    end
  end
end

local function playFollow3D(sound3d)
  if not (api and sound3d and sound3d.path and sound3d.path ~= "") then return end
  if not (api.playOwn and api.setPosition and api.setGain and sound3d.followKind and sound3d.followId ~= nil) then
    play3D(sound3d.path, sound3d.x, sound3d.y, sound3d.fullRange, sound3d.maxRange, sound3d.gain)
    return
  end
  updateAudioListener()
  local target = findFollowAudioTarget(sound3d.followKind, sound3d.followId)
  local x = target and target.x or sound3d.x
  local y = target and target.y or sound3d.y
  local pos = audioRelativePosition(x, y)
  local gain = audioGainForDistance(audioDistance(pos), sound3d.fullRange, sound3d.maxRange) * (sound3d.gain or 1)
  if gain <= 0 then return end
  rangedAudioSeq = rangedAudioSeq + 1
  local name = "frontline_follow_" .. tostring(rangedAudioSeq)
  followAudios[name] = {kind=sound3d.followKind, id=sound3d.followId, fullRange=sound3d.fullRange, maxRange=sound3d.maxRange, gain=sound3d.gain or 1, expireAt=(api.time and api.time() or 0) + (sound3d.followDuration or 3)}
  local sa = getSpatialAudio()
  if sa and sa.playNamed(name, sound3d.path, true, pos.x, pos.z, gain, sound3d.fullRange or AUDIO_FULL_VOLUME_RANGE, sound3d.maxRange or AUDIO_MAX_HEAR_RANGE, 20) then
    followAudios[name].spatial = true
    return
  end
  api.playOwn(name, sound3d.path, function()
    followAudios[name] = nil
    if api and api.releaseAudio then api.releaseAudio(name) end
  end)
  api.setPosition(name, pos)
  api.setGain(name, gain)
end

local function playUiBrowse()
  play2D(UI_SOUND_BROWSE)
end

local function playUiConfirm()
  play2D(UI_SOUND_CONFIRM)
end

local function playUiBack()
  play2D(UI_SOUND_BACK)
end

local function playEventAudio(data)
  if not data then return end
  if data.sound then play2D(data.sound) end
  if data.sound3d then playFollow3D(data.sound3d) end
end

local navGainForTarget
local function stopNavAudio()
  if navAudioSpatial then
    local sa = getSpatialAudio()
    if sa then sa.releaseNamed(NAV_AUDIO_NAME) end
  end
  navAudioSpatial = false
  if api and api.releaseAudio then api.releaseAudio(NAV_AUDIO_NAME) elseif api and api.stopAudio then api.stopAudio(NAV_AUDIO_NAME) end
end

local function navAudioPosition(ref)
  if not ref then return nil end
  return audioRelativePosition(ref.x, ref.y)
end

local function updateNavAudioPosition(ref)
  if not ref then return false end
  updateAudioListener()
  local pos = navAudioPosition(ref)
  if not pos then return false end
  local gain = navGainForTarget(myPlayer and myPlayer() or nil, ref)
  if navAudioSpatial then
    local sa = getSpatialAudio()
    if sa then
      sa.setNamedPosition(NAV_AUDIO_NAME, pos.x, pos.z)
      sa.setNamedGain(NAV_AUDIO_NAME, gain)
      return true
    end
  end
  return false
end

navGainForTarget = function(me, target)
  if not me or not target then return 1 end
  local dx = (target.x or 0) - (me.x or 0)
  local dy = (target.y or 0) - (me.y or 0)
  return audioGainForDistance(math.sqrt(dx * dx + dy * dy)) * NAV_AUDIO_GAIN_SCALE
end

local function playPrivateNavBeep(ref)
  if not (api and ref) then return false end
  updateAudioListener()
  local pos = navAudioPosition(ref)
  if not pos then return false end
  local gain = navGainForTarget(myPlayer and myPlayer() or nil, ref)
  local sa = getSpatialAudio()
  if sa and sa.playOnce(NAV_AUDIO_PATH, pos.x, pos.z, gain, AUDIO_FULL_VOLUME_RANGE, AUDIO_MAX_HEAR_RANGE, 20) then
    navAudioSpatial = false
    return true
  end
  -- Realtime target navigation must be spatialized by SteamAudio. Do not fall back to
  -- native playOwn here, because that API attaches the beep to the listener/self.
  navAudioSpatial = false
  return false
end

local function crystalIdleName(id)
  return "frontline_crystal_idle_" .. tostring(id)
end

local function releaseCrystalIdleAudio(name)
  if not name then return end
  local entry = crystalIdleAudio[name]
  if entry and entry.spatial then
    local sa = getSpatialAudio()
    if sa then sa.releaseNamed(name) end
  end
  if api and api.releaseAudio then api.releaseAudio(name) elseif api and api.stopAudio then api.stopAudio(name) end
end

local function clearCrystalIdleAudio()
  for name,_ in pairs(crystalIdleAudio) do releaseCrystalIdleAudio(name) end
  crystalIdleAudio = {}
end

local function updateCrystalIdleAudio()
  if phase ~= "battle" or not api then
    if phase ~= "battle" then clearCrystalIdleAudio() end
    return
  end
  local alive = {}
  for _,b in ipairs(latest.buildings or {}) do
    if b.kind == "crystal" and b.hp and b.hp > 0 and b.id then
      local name = crystalIdleName(b.id)
      alive[name] = true
      local pos = audioRelativePosition(b.x, b.y)
      local gain = audioGainForDistance(audioDistance(pos), AUDIO_FULL_VOLUME_RANGE, AUDIO_MAX_HEAR_RANGE)
      local entry = crystalIdleAudio[name]
      if (not entry) then
        local sa = getSpatialAudio()
        if sa and sa.playNamed(name, CRYSTAL_IDLE_PATH, true, pos.x, pos.z, gain, AUDIO_FULL_VOLUME_RANGE, AUDIO_MAX_HEAR_RANGE, 20) then
          crystalIdleAudio[name] = { spatial = true }
        elseif api.playOwn and api.setPosition and api.setGain then
          api.playOwn(name, CRYSTAL_IDLE_PATH)
          crystalIdleAudio[name] = { spatial = false }
        end
      elseif entry.spatial then
        local sa = getSpatialAudio()
        if sa then
          sa.setNamedPosition(name, pos.x, pos.z)
          sa.setNamedGain(name, gain)
        end
      elseif api.setPosition and api.setGain then
        api.setPosition(name, pos)
        api.setGain(name, gain)
      end
    end
  end
  for name,_ in pairs(crystalIdleAudio) do
    if not alive[name] then
      releaseCrystalIdleAudio(name)
      crystalIdleAudio[name] = nil
    end
  end
end


local function terrainFootstepGroup(terrain)
  if terrain == "blue_spawn" or terrain == "red_spawn" then return "base" end
  if terrain == "jungle" or terrain == "jungle_entry" then return "jungle" end
  if terrain == "river" then return "river" end
  return "lane"
end

local FOOTSTEP_EVENT_PREFIX = {
  base = "basefootstep",
  jungle = "junglefootstep",
  lane = "lanefootstep",
  river = "riverfootstep"
}

local function refillFootstepOrder()
  footstepOrder[1] = 1
  footstepOrder[2] = 2
  footstepOrder[3] = 3
  footstepOrder[4] = 4
  for i=4,2,-1 do
    local j = math.random(i)
    footstepOrder[i], footstepOrder[j] = footstepOrder[j], footstepOrder[i]
  end
  footstepOrderIndex = 1
end

local function nextFootstepVariant()
  if footstepOrderIndex > 4 then refillFootstepOrder() end
  local variant = footstepOrder[footstepOrderIndex] or math.random(1,4)
  footstepOrderIndex = footstepOrderIndex + 1
  return variant
end

local function playFootstep()
  local p = myPlayer()
  if not p then return end
  local group = terrainFootstepGroup(p.terrain)
  local prefix = FOOTSTEP_EVENT_PREFIX[group] or FOOTSTEP_EVENT_PREFIX.lane
  local path = "movement/" .. prefix .. tostring(nextFootstepVariant())
  play3D(path, p.x, p.y)
end

local function moveKey(dx, dy)
  dx = dx or 0
  dy = dy or 0
  dx = dx > 0 and 1 or (dx < 0 and -1 or 0)
  dy = dy > 0 and 1 or (dy < 0 and -1 or 0)
  return tostring(dx) .. "," .. tostring(dy)
end

local function currentMoveKey()
  if moveState.x == 0 and moveState.y == 0 then return nil end
  return moveKey(moveState.x, moveState.y)
end

local function moveResultMatchesCurrent(dx, dy)
  local currentKey = currentMoveKey()
  if not currentKey then return false end
  local resultKey = moveKey(dx, dy)
  if currentKey == resultKey then return true end
  dx = dx or 0
  dy = dy or 0
  dx = dx > 0 and 1 or (dx < 0 and -1 or 0)
  dy = dy > 0 and 1 or (dy < 0 and -1 or 0)
  if dx ~= 0 and dx == moveState.x then return true end
  if dy ~= 0 and dy == moveState.y then return true end
  return false
end

local function clearBlockedMoveIfChanged()
  local key = currentMoveKey()
  if blockedMoveKey and blockedMoveKey ~= key then blockedMoveKey = nil end
end

local function markPendingFootstep()
  local key = currentMoveKey()
  if key then pendingFootstepKey = key end
end

local function currentFootstepInterval()
  local p = myPlayer and myPlayer()
  local speedBonus = math.max(0, ((p and p.speed) or FOOTSTEP_BASE_SPEED) - FOOTSTEP_BASE_SPEED)
  local speedMultiplier = 1 + speedBonus * 0.2
  return FOOTSTEP_INTERVAL / speedMultiplier
end

local function playHeldFootstepIfDue(t)
  local key = currentMoveKey()
  if not key or key == blockedMoveKey then return end
  if not confirmedMoveKey then return end
  if t >= (nextFootstepAt or 0) then
    playFootstep()
    nextFootstepAt = t + currentFootstepInterval()
  end
end


local function send(data)
  if api and selfIndex and selfIndex > 0 then api.send(data) end
end

local function sendAny(data)
  if api and api.send then api.send(data) end
end

local function playerByIndex(index)
  for _,p in ipairs(latest.players or {}) do if p.index == index then return p end end
  return nil
end

local function sortedPlayerIndexes()
  local list = {}
  for _,p in ipairs(latest.players or {}) do
    if p.index then list[#list+1] = p.index end
  end
  table.sort(list)
  return list
end

local function firstSpectatorIndex()
  local list = sortedPlayerIndexes()
  if #list == 0 then return nil end
  if playerByIndex(modeHost) then return modeHost end
  if playerByIndex(1) then return 1 end
  return list[1]
end

local function ensureSpectatorViewIndex()
  if selfIndex > 0 then return selfIndex end
  if spectatorViewIndex and playerByIndex(spectatorViewIndex) then return spectatorViewIndex end
  spectatorViewIndex = firstSpectatorIndex()
  return spectatorViewIndex
end

function myPlayer()
  local index = selfIndex
  if selfIndex <= 0 then index = ensureSpectatorViewIndex() end
  return playerByIndex(index)
end

local function spectatorViewName(p)
  if not p then return "没有可观战玩家" end
  return "观战" .. tostring(p.name or ("玩家" .. tostring(p.index or "")))
end

local function notifySpectatorTarget()
  if selfIndex > 0 or not spectatorViewIndex or lastSpectatorNotifyIndex == spectatorViewIndex then return end
  lastSpectatorNotifyIndex = spectatorViewIndex
  sendAny({type="spectateTarget", targetIndex=spectatorViewIndex})
end

local function speakSpectatorView()
  local p = playerByIndex(ensureSpectatorViewIndex())
  speak(spectatorViewName(p))
  notifySpectatorTarget()
end

local function cycleSpectatorView(delta)
  local list = sortedPlayerIndexes()
  if #list == 0 then speak("没有可观战玩家。") return true end
  local cur = ensureSpectatorViewIndex() or list[1]
  local pos = 1
  for i,v in ipairs(list) do if v == cur then pos = i; break end end
  pos = pos + delta
  if pos < 1 then pos = #list end
  if pos > #list then pos = 1 end
  spectatorViewIndex = list[pos]
  playUiBrowse()
  speakSpectatorView()
  return true
end

local function isAvailable(id)
  for _,v in ipairs(available or {}) do if v == id then return true end end
  return false
end

local function normalizeModeCursor()
  if #battleModes == 0 then modeCursor = 1; return end
  if modeCursor < 1 then modeCursor = #battleModes end
  if modeCursor > #battleModes then modeCursor = 1 end
end

local function speakCurrentMode()
  normalizeModeCursor()
  local mode = battleModes[modeCursor]
  if not mode then return end
  local perTeam = mode.perTeam or 0
  local name = mode.name or mode.id or "未知战场"
  if perTeam > 0 then
    speak(name .. "，" .. tostring(perTeam) .. "人对" .. tostring(perTeam) .. "人")
  else
    speak(name)
  end
end

local function normalizePickCursor()
  if #heroOrder == 0 then pickCursor = 1; return end
  if pickCursor < 1 then pickCursor = #heroOrder end
  if pickCursor > #heroOrder then pickCursor = 1 end
  local tries = 0
  while tries < #heroOrder and not isAvailable(heroOrder[pickCursor]) do
    pickCursor = pickCursor + 1
    if pickCursor > #heroOrder then pickCursor = 1 end
    tries = tries + 1
  end
end

local function speakCurrentHero()
  normalizePickCursor()
  local id = heroOrder[pickCursor]
  if id and heroes[id] then speak(heroes[id].name .. "。" .. heroes[id].core) end
end

local function nearShop(p)
  if not p then return false end
  for _,s in ipairs(latest.shops or {}) do
    local dx = p.x - s.x; local dy = p.y - s.y
    if math.sqrt(dx*dx + dy*dy) <= 5 then return true end
  end
  return false
end

local function currentShopItem()
  local items = latest.items or {}
  if #items == 0 then return nil end
  if shopCursor < 1 then shopCursor = #items end
  if shopCursor > #items then shopCursor = 1 end
  return items[shopCursor]
end

local function hasOwnedItem(item)
  local p = myPlayer()
  if not p or not item then return false end
  for _,id in ipairs(p.itemIds or {}) do if id == item.id then return true end end
  for _,name in ipairs(p.itemNames or {}) do if name == item.name then return true end end
  return false
end

local function speakShopItem()
  local it = currentShopItem()
  if not it then speak("没有商品。") return end
  if hasOwnedItem(it) then speak("已购买" .. it.name); return end
  local attrs = {}
  if it.atk then table.insert(attrs, "攻击加" .. tostring(it.atk)) end
  if it.def then table.insert(attrs, "防御加" .. tostring(it.def)) end
  if it.hp then table.insert(attrs, "生命加" .. tostring(it.hp)) end
  if it.speed then table.insert(attrs, "速度加" .. tostring(math.floor(it.speed * 20 + 0.5))) end
  local text = it.name .. "，" .. tostring(it.price or 0) .. "金币"
  if #attrs > 0 then text = text .. "，" .. table.concat(attrs, "，") end
  speak(text)
end

local function openShop()
  local p = myPlayer()
  if not nearShop(p) then speak("不在商店范围内。") return end
  shopOpen = true; shopCursor = 1
  playUiConfirm()
  speak("打开商店。")
  speakShopItem()
end

local function closeShop()
  if shopOpen then shopOpen = false; playUiBack(); speak("关闭商店。") end
end

local function buyCurrent()
  local it = currentShopItem()
  if it then send({type="buy", item=it.id}) end
end

local function teamText(t)
  return t == "blue" and "蓝方" or "红方"
end

local function playerName(index)
  for _,p in ipairs(latest.players or {}) do if p.index == index then return p.name or ("玩家" .. index) end end
  return "目标"
end

local function targetList()
  local me = myPlayer()
  local list = {}
  if not me then return list end

  local vision2 = 20 * 20

  local function inVision(obj)
    if not obj or obj.x == nil or obj.y == nil then return false end
    local dx = (me.x or 0) - obj.x
    local dy = (me.y or 0) - obj.y
    return dx * dx + dy * dy <= vision2
  end

  local function addTarget(kind, ref, name)
    if not ref or ref == me or ref.index == selfIndex or not inVision(ref) then return end
    table.insert(list, {kind=kind, ref=ref, name=name})
  end

  for _,p in ipairs(latest.players or {}) do
    if not p.dead then
      if targetMode == "all" or (targetMode == "enemy" and p.team ~= me.team) or (targetMode == "ally" and p.team == me.team) then
        addTarget("player", p, p.name or (p.team == me.team and "队友" or "敌方玩家"))
      end
    end
  end
  for _,b in ipairs(latest.buildings or {}) do
    if (b.hp or 0) > 0 and (targetMode == "all" or b.team == nil or (targetMode == "enemy" and b.team ~= me.team) or (targetMode == "ally" and b.team == me.team)) then
      addTarget(b.kind, b, b.name or (b.kind == "crystal" and "水晶塔" or "防御塔"))
    end
  end
  if targetMode == "all" then
    for _,s in ipairs(latest.shops or {}) do
      addTarget("shop", s, s.name or "商店")
    end
  end
  if targetMode == "all" or targetMode == "enemy" then
    for _,m in ipairs(latest.monsters or {}) do
      if not m.dead and (m.hp or 1) > 0 then
        addTarget("monster", m, m.name or "野怪")
      end
    end
  end
  table.sort(list, function(a,b)
    local da = (me.x-a.ref.x)*(me.x-a.ref.x)+(me.y-a.ref.y)*(me.y-a.ref.y)
    local db = (me.x-b.ref.x)*(me.x-b.ref.x)+(me.y-b.ref.y)*(me.y-b.ref.y)
    return da < db
  end)
  return list
end

local function targetRefId(kind, ref)
  if not ref then return nil end
  if kind == "player" then return ref.index end
  return ref.id or ref.index
end

local function sameTargetRef(a, kind, ref)
  if not a or not kind or not ref then return false end
  local id = targetRefId(kind, ref)
  return a.kind == kind and tostring(a.id) == tostring(id)
end

local function lockTarget(t)
  if t and t.ref then
    local id = targetRefId(t.kind, t.ref)
    if id ~= nil then
      lockedTarget = {kind=t.kind, id=id}
      return
    end
  end
  lockedTarget = nil
end

local function targetIndexByLock(list)
  if not lockedTarget then return nil end
  for i,t in ipairs(list or {}) do
    if sameTargetRef(lockedTarget, t.kind, t.ref) then return i end
  end
  return nil
end

local function currentTarget()
  local list = targetList()
  if #list == 0 then targetCursor = 1; lockedTarget = nil; return nil end
  local lockedIndex = targetIndexByLock(list)
  if lockedIndex then
    targetCursor = lockedIndex
    return list[lockedIndex]
  end
  if targetCursor < 1 then targetCursor = #list end
  if targetCursor > #list then targetCursor = 1 end
  local t = list[targetCursor]
  lockTarget(t)
  return t
end

local function currentTargetRef()
  local t = currentTarget()
  if not t or not t.ref then return nil end
  return {kind=t.kind, id=targetRefId(t.kind, t.ref)}
end

local function sendSkill(slot)
  local data = {type="skill", slot=slot}
  local tr = currentTargetRef()
  if tr then data.targetKind = tr.kind; data.targetId = tr.id end
  send(data)
end

local function targetAlive(t)
  if not t or not t.ref then return false end
  local r = t.ref
  if r.dead then return false end
  if r.hp ~= nil and r.hp <= 0 then return false end
  return true
end

local function navTargetKey(t)
  if not t or not t.ref then return nil end
  local r = t.ref
  return {kind=t.kind, id=r.id, index=r.index, x=r.x, y=r.y, name=t.name}
end

local function sameNavRef(key, kind, ref)
  if not key or not ref then return false end
  if key.kind ~= kind then return false end
  if key.id ~= nil and ref.id ~= nil then return key.id == ref.id end
  if key.index ~= nil and ref.index ~= nil then return key.index == ref.index end
  return key.x == ref.x and key.y == ref.y
end

local function clearNavTarget()
  navTarget = nil
  stopNavAudio()
end

local function navTargetLooksLikeSelf(kind, ref)
  local me = myPlayer and myPlayer() or nil
  if not me or not ref then return false end
  if ref == me then return true end
  if kind == "player" and ref.index ~= nil and me.index ~= nil and ref.index == me.index then return true end
  return false
end

local function setNavTarget(t)
  if targetAlive(t) and not navTargetLooksLikeSelf(t.kind, t.ref) then navTarget = navTargetKey(t) else navTarget = nil end
  return navTarget ~= nil
end

local function resolvedNavTarget()
  if not navTarget then return nil end
  local function pack(kind, ref, name)
    if navTargetLooksLikeSelf(kind, ref) then navTarget = nil; return nil end -- navigation target is self; avoid beep at listener origin
    local t = {kind=kind, ref=ref, name=name or navTarget.name or "目标"}
    if targetAlive(t) then return t end
    return nil
  end
  for _,p in ipairs(latest.players or {}) do
    if sameNavRef(navTarget, "player", p) then return pack("player", p, p.name) end
  end
  for _,b in ipairs(latest.buildings or {}) do
    if sameNavRef(navTarget, b.kind, b) then return pack(b.kind, b, b.name or (b.kind == "crystal" and "水晶塔" or "防御塔")) end
  end
  for _,s in ipairs(latest.shops or {}) do
    if sameNavRef(navTarget, "shop", s) then return pack("shop", s, s.name or "商店") end
  end
  for _,m in ipairs(latest.monsters or {}) do
    if sameNavRef(navTarget, "monster", m) then return pack("monster", m, m.name or "野怪") end
  end
  navTarget = nil
  return nil
end

local function speakTarget()
  local me = myPlayer()
  local t = currentTarget()
  if not me or not t then return false end
  local r = t.ref
  local dx = (me.x or 0) - (r.x or 0)
  local dy = (me.y or 0) - (r.y or 0)
  local distance = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
  speak(tostring(distance) .. "米" .. t.name)
  return true
end

local function speakTargetHp()
  local t = currentTarget()
  if not t or not t.ref then return end
  local hp = t.ref.hp
  if hp == nil then return end
  speak(tostring(math.floor(hp or 0)))
end

local function speakSelfHp()
  local p = myPlayer()
  if not p then speak("没有角色数据。") return end
  local statuses = p.statuses or {}
  local names = {}
  local map = {slow="减速", stun="眩晕", freeze="冻结", poison="中毒", burn="燃烧", weaken="虚弱"}
  for _,s in ipairs(statuses) do
    if s ~= "invuln" then table.insert(names, map[s] or s) end
  end
  local text = tostring(math.floor(p.hp or 0))
  if #names > 0 then text = text .. "，" .. table.concat(names, "，") end
  text = text .. "，等级" .. tostring(p.level or 1)
  speak(text)
end

local function speakSelfGold()
  local p = myPlayer()
  if not p then speak("没有角色数据。") return end
  speak(tostring(math.floor(p.gold or 0)) .. "金币")
end

local function speakSelfEquipmentCount()
  local p = myPlayer()
  if not p then speak("没有角色数据。") return end
  speak("当前穿了" .. tostring(p.equipmentCount or 0) .. "件装备")
end

local function updateTerrainSpeak()
  if phase ~= "battle" then return end
  local p = myPlayer()
  if not p or not p.terrainName or p.terrainName == "" then return end
  if p.terrainName ~= lastTerrainName then
    lastTerrainName = p.terrainName
    speak(p.terrainName)
  end
end

local function speakCoord()
  local p = myPlayer()
  if not p then return end
  local text = "坐标" .. math.floor(p.x) .. "，" .. math.floor(p.y) .. "。"
  if p.terrainName and p.terrainName ~= "" then text = text .. p.terrainName .. "。" end
  speak(text)
end
local function toggleTargetMode()
  if targetMode == "all" then
    targetMode = "enemy"
  elseif targetMode == "enemy" then
    targetMode = "ally"
  else
    targetMode = "all"
  end
  targetCursor = 1
  lockedTarget = nil
  if targetMode == "all" then
    speak("所有")
  elseif targetMode == "enemy" then
    speak("敌方")
  else
    speak("己方")
  end
end

local function cycleTarget(delta, soundPath)
  local list = targetList()
  if #list == 0 then targetCursor = 1; lockedTarget = nil; return end
  local currentIndex = targetIndexByLock(list) or targetCursor
  targetCursor = currentIndex + delta
  if targetCursor < 1 then targetCursor = #list end
  if targetCursor > #list then targetCursor = 1 end
  lockTarget(list[targetCursor])
  if speakTarget() then
    local t = currentTarget()
    if navOn then setNavTarget(t) end
    if t and t.ref then play3D("ui/targetlocate", t.ref.x, t.ref.y) elseif soundPath then play2D(soundPath) end
  end
end

local function targetDistance(me, t)
  if not me or not t or not t.ref then return nil end
  local dx = (t.ref.x or 0) - (me.x or 0)
  local dy = (t.ref.y or 0) - (me.y or 0)
  return math.sqrt(dx * dx + dy * dy)
end

local function playNavBeep()
  local t = resolvedNavTarget()
  if not t or not t.ref then return false end
  return playPrivateNavBeep(t.ref)
end

local function navInterval()
  local me = myPlayer(); local t = resolvedNavTarget()
  local d = targetDistance(me, t)
  if not d then return NAV_MAX_INTERVAL end
  local minD = AUDIO_FULL_VOLUME_RANGE
  local maxD = AUDIO_MAX_HEAR_RANGE
  if d <= minD then return NAV_MIN_INTERVAL end
  if d >= maxD then return NAV_MAX_INTERVAL end
  local normalized = (d - minD) / (maxD - minD)
  -- Smooth monotonic cadence: near target = faster beeps, far target = slower beeps.
  return NAV_MIN_INTERVAL + (NAV_MAX_INTERVAL - NAV_MIN_INTERVAL) * (normalized ^ 1.15)
end

local function updateMove(ds)
  if phase ~= "battle" or shopOpen then return end
  if moveState.x == 0 and moveState.y == 0 then return end
  local t = api and api.time and api.time() or 0
  clearBlockedMoveIfChanged()
  if t - lastMoveSend >= 0.05 then
    lastMoveSend = t
    send({type="move", dx=moveState.x, dy=moveState.y})
  end
  playHeldFootstepIfDue(t)
end

local function handleModeSelectKey(keycode)
  if selfIndex <= 0 then return true end
  if not modeHost or modeHost <= 0 or selfIndex ~= modeHost then return true end
  if keycode == C("K_LEFT",80) then modeCursor = modeCursor - 1; playUiBrowse(); speakCurrentMode(); return true end
  if keycode == C("K_RIGHT",79) then modeCursor = modeCursor + 1; playUiBrowse(); speakCurrentMode(); return true end
  if keycode == C("K_ENTER",40) then
    normalizeModeCursor()
    local mode = battleModes[modeCursor]
    if mode and mode.id then playUiConfirm(); send({type="battleMode", mode=mode.id}) end
    return true
  end
  return false
end

local function handlePickKey(keycode)
  if keycode == C("K_LEFT",80) then pickCursor = pickCursor - 1; playUiBrowse(); speakCurrentHero(); return true end
  if keycode == C("K_RIGHT",79) then pickCursor = pickCursor + 1; playUiBrowse(); speakCurrentHero(); return true end
  if keycode == C("K_ENTER",40) then
    normalizePickCursor()
    local id = heroOrder[pickCursor]
    if id then playUiConfirm(); send({type="pick", hero=id}) end
    return true
  end
  return false
end

local function handleShopKey(keycode)
  if not shopOpen then return false end
  if keycode == C("K_W",26) then shopCursor = shopCursor - 1; playUiBrowse(); speakShopItem(); return true end
  if keycode == C("K_S",22) then shopCursor = shopCursor + 1; playUiBrowse(); speakShopItem(); return true end
  if keycode == C("K_ENTER",40) then playUiConfirm(); buyCurrent(); return true end
  if keycode == C("K_ESC",41) then closeShop(); return true end
  return true
end

local function sf_start(membersArray, index, nativeapi, again, timeoutSec)
  members = membersArray or {}; selfIndex = index or 0; api = nativeapi
  phase = "idle"; moveState = {x=0,y=0}; blockedMoveKey=nil; confirmedMoveKey=nil; pendingFootstepKey=nil; shopOpen=false; navOn=false; clearNavTarget(); clearCrystalIdleAudio()
  spectatorViewIndex=nil; leftWinDown=false; lastSpectatorNotifyIndex=nil
  battleModes = {}; modeCursor = 1; modeHost = 0
  lastTerrainName = nil
  if selfIndex == 0 then speak("旁观模式。") end
end

local function sf_over()
  navOn = false; clearNavTarget(); shopOpen = false; blockedMoveKey=nil; confirmedMoveKey=nil; pendingFootstepKey=nil; clearCrystalIdleAudio()
  if spatialAudio then spatialAudio.shutdown() end
end

local function sf_clean()
  navOn = false; clearNavTarget(); shopOpen = false; blockedMoveKey=nil; confirmedMoveKey=nil; pendingFootstepKey=nil; clearCrystalIdleAudio()
  if spatialAudio then spatialAudio.shutdown() end
end

local function sf_message(data, index)
  if not data then return end
  if data.type == "modeSelectStart" then
    phase = "mode_select"; battleModes = data.modes or {}; modeCursor = 1; modeHost = data.host or 0
    if (not modeHost or modeHost <= 0) and members and members[1] then modeHost = 1 end
    if selfIndex > 0 and modeHost > 0 and selfIndex == modeHost then speak(data.text or "请选择战场类型。"); speakCurrentMode() end
  elseif data.type == "modeSelected" then
    local mode = data.mode or {}
    speak(data.text or ("战场类型已选择：" .. (mode.name or mode.id or "未知") .. "。"))
  elseif data.type == "pickStart" then
    phase = "pick"; team = data.team; heroes = data.heroes or {}; heroOrder = data.order or {}; available = data.available or {}; pickCursor = 1
    speak("你在" .. teamText(team) .. "。左右方向键浏览角色，回车确认。")
    speakCurrentHero()
  elseif data.type == "pickUpdate" then
    if data.team == team then available = data.available or available; normalizePickCursor() end
  elseif data.type == "picked" then
    pickedHero = data.hero; speak("已选择" .. (data.name or "角色") .. "。")
  elseif data.type == "battleStart" then
    phase = "battle"; shopOpen=false; speak(data.text or "战斗开始。")
  elseif data.type == "snapshot" then
    phase = data.phase or phase
    latest.players = data.players or latest.players
    latest.buildings = data.buildings or latest.buildings
    latest.monsters = data.monsters or latest.monsters
    latest.shops = data.shops or latest.shops
    latest.items = data.items or latest.items
    if data.heroes then heroes = data.heroes end
    if data.order then heroOrder = data.order end
    if selfIndex <= 0 and not spectatorViewIndex and firstSpectatorIndex() then
      spectatorViewIndex = firstSpectatorIndex()
      speakSpectatorView()
    end
    updateTerrainSpeak()
    updateFollowAudios()
    updateCrystalIdleAudio()
  elseif data.type == "event" then
    playEventAudio(data)
    if data.text then speak(data.text) end
  elseif data.type == "spectatorNotice" then
    if data.text then speak(data.text) end
  elseif data.type == "moveResult" then
    local key = moveKey(data.dx, data.dy)
    if data.moved then
      if blockedMoveKey == key then blockedMoveKey = nil end
      local t = api and api.time and api.time() or 0
      local currentKey = currentMoveKey()
      local matchesCurrent = moveResultMatchesCurrent(data.dx, data.dy)
      if pendingFootstepKey == key or (pendingFootstepKey and matchesCurrent) then
        playFootstep()
        nextFootstepAt = t + FOOTSTEP_INTERVAL
        pendingFootstepKey = nil
      end
      if matchesCurrent then
        confirmedMoveKey = currentKey
      elseif currentKey and confirmedMoveKey then
        -- Keep footsteps continuous while stale move confirmations from the previous direction arrive.
      else
        confirmedMoveKey = nil
      end
    else
      blockedMoveKey = key
      local matchesCurrent = moveResultMatchesCurrent(data.dx, data.dy)
      if confirmedMoveKey == key or matchesCurrent then confirmedMoveKey = nil end
      if pendingFootstepKey == key or (pendingFootstepKey and matchesCurrent) then pendingFootstepKey = nil end
    end
  elseif data.type == "over" then
    phase = "over"; navOn=false; blockedMoveKey=nil; confirmedMoveKey=nil; pendingFootstepKey=nil; clearNavTarget(); clearCrystalIdleAudio()
    if data.winner and team and data.winner == team then play2D("ui/victory") elseif data.winner then play2D("ui/defeat") end
    speak(data.text or "战斗结束。")
  end
end

local function handleSpectatorKey(keycode, repeated)
  if keycode == C("K_LGUI",227) then leftWinDown = true; return true end
  if leftWinDown and keycode == C("K_LEFT",80) then return cycleSpectatorView(-1) end
  if leftWinDown and keycode == C("K_RIGHT",79) then return cycleSpectatorView(1) end
  return true
end

local function sf_keydown(keycode, repeated)
  if selfIndex <= 0 then handleSpectatorKey(keycode, repeated); return end
  if phase == "mode_select" and handleModeSelectKey(keycode) then return end
  if phase == "pick" and handlePickKey(keycode) then return end
  if handleShopKey(keycode) then return end

  if phase ~= "battle" then return end
  if keycode == C("K_W",26) then
    local wasIdle = moveState.x == 0 and moveState.y == 0
    moveState.y = 1
    clearBlockedMoveIfChanged()
    if wasIdle and not repeated then markPendingFootstep() end
    send({type="move", dx=moveState.x, dy=moveState.y}); lastMoveSend = api and api.time and api.time() or lastMoveSend
    return
  end
  if keycode == C("K_S",22) then
    local wasIdle = moveState.x == 0 and moveState.y == 0
    moveState.y = -1
    clearBlockedMoveIfChanged()
    if wasIdle and not repeated then markPendingFootstep() end
    send({type="move", dx=moveState.x, dy=moveState.y}); lastMoveSend = api and api.time and api.time() or lastMoveSend
    return
  end
  if keycode == C("K_A",4) then
    local wasIdle = moveState.x == 0 and moveState.y == 0
    moveState.x = -1
    clearBlockedMoveIfChanged()
    if wasIdle and not repeated then markPendingFootstep() end
    send({type="move", dx=moveState.x, dy=moveState.y}); lastMoveSend = api and api.time and api.time() or lastMoveSend
    return
  end
  if keycode == C("K_D",7) then
    local wasIdle = moveState.x == 0 and moveState.y == 0
    moveState.x = 1
    clearBlockedMoveIfChanged()
    if wasIdle and not repeated then markPendingFootstep() end
    send({type="move", dx=moveState.x, dy=moveState.y}); lastMoveSend = api and api.time and api.time() or lastMoveSend
    return
  end

  if keycode == C("K_ENTER",40) then openShop(); return end
  if keycode == C("K_ESC",41) then closeShop(); return end
  if keycode == C("K_Z",29) then toggleTargetMode(); return end
  if keycode == C("K_ZFK",47) then cycleTarget(-1, "ui/targetback"); return end
  if keycode == C("K_YFK",48) then cycleTarget(1, "ui/targetfront"); return end
  if keycode == C("K_R",21) then speakSelfHp(); return end
  if keycode == C("K_Q",20) then speakSelfGold(); return end
  if keycode == C("K_E",8) then speakSelfEquipmentCount(); return end
  if keycode == C("K_PE",53) then speakTargetHp(); return end
  if keycode == C("K_V",25) then speakCoord(); return end
  if keycode == C("K_P",19) then
    navOn = not navOn
    navNext = 0
    if navOn then
      setNavTarget(currentTarget())
      speak("目标导航开启。")
    else
      clearNavTarget()
      speak("目标导航关闭。")
    end
    return
  end

  if keycode == C("K_J",13) then sendSkill(1); return end
  if keycode == C("K_K",14) then sendSkill(2); return end
  if keycode == C("K_L",15) then sendSkill(3); return end
  if keycode == C("K_FH",51) then sendSkill(4); return end
  if keycode == C("K_DYH",52) then sendSkill(5); return end
end

local function sf_keyup(keycode)
  if keycode == C("K_LGUI",227) then leftWinDown = false; return end
  if selfIndex <= 0 then return end
  local wasMovingConfirmed = confirmedMoveKey ~= nil
  if keycode == C("K_W",26) and moveState.y == 1 then moveState.y = 0 end
  if keycode == C("K_S",22) and moveState.y == -1 then moveState.y = 0 end
  if keycode == C("K_A",4) and moveState.x == -1 then moveState.x = 0 end
  if keycode == C("K_D",7) and moveState.x == 1 then moveState.x = 0 end
  clearBlockedMoveIfChanged()
  if moveState.x == 0 and moveState.y == 0 then
    blockedMoveKey = nil
    confirmedMoveKey = nil
    send({type="move", dx=0, dy=0})
  elseif wasMovingConfirmed then
    confirmedMoveKey = currentMoveKey()
    send({type="move", dx=moveState.x, dy=moveState.y})
    lastMoveSend = api and api.time and api.time() or lastMoveSend
  end
end

local function sf_touch(touchtype, x, y, fingers, gid)
end

local function sf_update(ds)
  updateMove(ds or 0)
  if spatialAudio then spatialAudio.update(ds or 0) end
  updateAudioListener()
  updateFollowAudios()
  updateCrystalIdleAudio()
  if navOn and phase == "battle" then
    local nav = resolvedNavTarget()
    if nav and nav.ref then
      updateNavAudioPosition(nav.ref)
      local t = api and api.time and api.time() or 0
      if t >= navNext then
        if not playNavBeep() then clearNavTarget() end
        navNext = t + navInterval()
      end
    else
      clearNavTarget()
    end
  end
end

return {
  start = sf_start,
  over = sf_over,
  clean = sf_clean,
  message = sf_message,
  keydown = sf_keydown,
  keyup = sf_keyup,
  touch = sf_touch,
  update = sf_update
}


