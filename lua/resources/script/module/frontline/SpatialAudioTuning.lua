-- SteamAudio 3D runtime tuning for Frontline sound3d only.
-- Change these values, save, then restart the game to test spatial perception.
-- This file intentionally does not affect TTS/speak, 2D UI sounds, BGM, or gameplay logic.
return {
  -- If left/right are reversed, toggle invertX.
  invertX = false,

  -- If front/back are reversed, toggle invertY.
  invertY = false,

  -- If game X/Y axes appear swapped in headphones, toggle axisSwap.
  axisSwap = false,

  -- Coordinate scaling before sending source positions to SteamAudio.
  xScale = 1.0,
  yScale = 1.0,

  -- Final 3D-only gain multiplier. Keep 1.0 unless 3D is globally too quiet/loud.
  gainScale = 1.0,

  -- Fallback ranges used when a sound3d event omits explicit ranges.
  minDistance = 1.0,
  maxDistance = 30.0,

  -- Listener basis used by SteamAudio. Forward defaults to +Z, up to +Y.
  listenerForward = { x = 0.0, y = 0.0, z = 1.0 },
  listenerUp = { x = 0.0, y = 1.0, z = 0.0 },

  -- Front/back enhancement for headphones. 0 disables rear low-pass; 0.2-0.5 is useful.
  -- This is intentionally plane-only: it changes rear timbre/gain but adds no up/down cue.
  rearLowpass = 0.0,
  rearGain = 1.0,

  -- Per-event override: crystal idle is a steady/tonal loop, so it needs a stronger rear cue
  -- than monsters or impact sounds. Key names are frontline.csv logical event keys.
  eventFrontBack = {
    ["combat/buildings/crystalidle"] = { rearLowpass = 0.0, rearGain = 1.0 },
  },
}



