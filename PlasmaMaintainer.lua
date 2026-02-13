-- Plasma Priority Maintainer for GTNH OpenComputers
-- Replaces AE2 Level Maintainer with priority-based plasma crafting.
-- Requires: OC adapter on ME Controller, Fluid Discretizer, AE2 patterns.
-- Usage: plasma_maintainer [scan|help]

local component = require("component")
local os = require("os")
local term = require("term")
local event = require("event")
local me = component.me_controller

if not me then
  print("ERROR: No ME Controller found! Connect an adapter to it.")
  return
end

-- Configuration
local CONFIG = {
  checkInterval   = 10,    -- seconds between stock checks
  idleSleepTime   = 60,    -- seconds to sleep when all targets met
  verbose         = true,  -- detailed logging
  craftTimeout    = 300,   -- seconds before craft is considered failed
  failCooldown    = 30,    -- seconds before retrying failed craft
  prioritizePower = true,  -- use strongest crafting CPU first
  cpuName         = nil,   -- specific crafting CPU name (nil = auto)
}

-- Load stock list (external file required)
local ok, stockList = pcall(dofile, "/home/stockList.lua")
if not ok or type(stockList) ~= "table" then
  print("ERROR: Could not load /home/stockList.lua")
  print("Create it with: return { {label='Helium Plasma', target=1000, batch=1, priority=100}, ... }")
  return
end
print("Loaded stockList.lua with " .. #stockList .. " entries.")

-- Sort by priority (highest first)
table.sort(stockList, function(a, b) return (a.priority or 0) > (b.priority or 0) end)

-- Terminal colors
local C = {
  R = "\27[0m", red = "\27[31m", grn = "\27[32m",
  yel = "\27[33m", mag = "\27[35m", cyn = "\27[36m", wht = "\27[37m",
}

local function log(msg, color)
  if CONFIG.verbose then
    print((color or C.wht) .. "[" .. os.date("%H:%M:%S") .. "] " .. msg .. C.R)
  end
end

local function fmtAmt(n)
  if n >= 1e6 then return string.format("%.1fM mB", n / 1e6)
  elseif n >= 1000 then return string.format("%.1fK mB", n / 1000)
  else return string.format("%d mB", n) end
end

-- Label helpers: Fluid Discretizer uses "drop of X" for items, "X" for fluids
local function dropLabel(l)  return l:sub(1,8) == "drop of " and l or ("drop of " .. l) end
local function cleanLabel(l) return l:sub(1,8) == "drop of " and l:sub(9) or l end

local function matchLabel(label, target)
  return target == label or target == cleanLabel(label) or target == dropLabel(label)
end

local function buildFilter(entry)
  local f = {}
  if entry.name then f.name = entry.name end
  if entry.damage then f.damage = entry.damage end
  return f
end

-- Query stored amount from ME network (tries fluids API first, then items)
local function getStoredAmount(entry)
  local lClean, lDrop = cleanLabel(entry.label), dropLabel(entry.label)

  local ok, fluids = pcall(me.getFluidsInNetwork)
  if ok and fluids then
    for _, f in ipairs(fluids) do
      if f.label == lClean then return f.amount or 0 end
    end
  end

  local filter = buildFilter(entry)
  local items = me.getItemsInNetwork(next(filter) and filter or {label = lDrop})
  if items then
    for _, item in ipairs(items) do
      if item.label == lDrop or item.label == lClean then return item.size or 0 end
    end
  end
  return 0
end

-- Find craftable object for entry
local function getCraftable(entry)
  local lDrop = dropLabel(entry.label)
  local filter = buildFilter(entry)

  local craftables = me.getCraftables(next(filter) and filter or {label = lDrop})
  if not craftables or #craftables == 0 then craftables = me.getCraftables() end

  if craftables then
    for _, c in ipairs(craftables) do
      local s = c.getItemStack()
      if s and matchLabel(entry.label, s.label) then return c end
    end
  end
  return nil
end

-- Craft tracking state
local activeCraft = nil      -- { request, entry, startTime }
local failCooldowns = {}     -- label -> timestamp
local recentlyCrafted = {}   -- label -> true (cleared each cycle)

-- Get CPU status: total, busy count, and whether any are free
local function getCpuInfo()
  local ok, cpus = pcall(me.getCpus)
  if not ok or not cpus then return 0, 0 end
  local busy = 0
  for _, cpu in ipairs(cpus) do if cpu.busy then busy = busy + 1 end end
  return #cpus, busy
end

local function getCpuStatus()
  local total, busy = getCpuInfo()
  return string.format("CPUs: %d/%d busy", busy, total)
end

-- Clears activeCraft with logging and sets recentlyCrafted
local function finishCraft(msg, color, setCooldown)
  local label = activeCraft.entry.label
  local elapsed = os.time() - activeCraft.startTime
  log(msg .. label .. " (after " .. elapsed .. "s)", color)
  recentlyCrafted[label] = true
  if setCooldown then
    failCooldowns[label] = os.time() + CONFIG.failCooldown
    log("  ⏸ Cooldown set: " .. CONFIG.failCooldown .. "s before retry", C.mag)
  end
  activeCraft = nil
end

local function isAnyCraftActive()
  if not activeCraft then return false end
  local req = activeCraft.request
  local elapsed = os.time() - activeCraft.startTime

  if req.isDone()     then finishCraft("✓ Craft done: ", C.grn, false)  return false end
  if req.isCanceled() then finishCraft("✗ Craft canceled (by player or AE2): ", C.red, false) return false end
  if req.hasFailed()  then finishCraft("✗ Craft failed (ingredients missing or unavailable): ", C.red, true) return false end

  if elapsed > CONFIG.craftTimeout then
    finishCraft("✗ Craft timeout (" .. CONFIG.craftTimeout .. "s limit): ", C.red, true)
    return false
  end
  return true
end

-- Check if AE2 is already crafting this item (our craft or external)
local function isCraftAlreadyRunning(entry)
  if activeCraft and activeCraft.entry.label == entry.label then return true end

  local ok, cpus = pcall(me.getCpus)
  if ok and cpus then
    for _, cpu in ipairs(cpus) do
      if cpu.busy and cpu.finalOutput and matchLabel(entry.label, cpu.finalOutput.label) then
        return true
      end
    end
  end
  return false
end

-- Request a craft from AE2
local function requestCraft(entry, craftable, deficit)
  local amount = math.min(entry.batch or 1, deficit)
  local total, busy = getCpuInfo()
  local cpuInfo = string.format("CPUs: %d/%d busy", busy, total)

  -- Pre-check: are any CPUs free?
  if total > 0 and busy >= total then
    log("⚠ All crafting CPUs busy, skipping: " .. entry.label .. " [" .. cpuInfo .. "]", C.yel)
    return false  -- no cooldown — retry next cycle when a CPU might be free
  end

  log("→ Requesting craft: " .. amount .. "x " .. entry.label ..
      " (Prio " .. (entry.priority or "?") .. ") [" .. cpuInfo .. "]", C.cyn)

  local req = CONFIG.cpuName
    and craftable.request(amount, CONFIG.prioritizePower, CONFIG.cpuName)
    or  craftable.request(amount, CONFIG.prioritizePower)

  if not req then
    log("✗ Craft request returned nil: " .. entry.label, C.red)
    log("  Likely cause: AE2 internal error or broken pattern", C.red)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false
  end

  os.sleep(0.5) -- let AE2 process

  if req.hasFailed() then
    -- CPUs were free (we checked above), so this is an actual ingredient problem
    log("⚠ Craft failed: " .. entry.label .. " — missing ingredients or circular dependency", C.yel)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false
  end
  if req.isCanceled() then
    log("⚠ Craft canceled: " .. entry.label .. " — CPU may have been taken by another request", C.yel)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false
  end

  activeCraft = { request = req, entry = entry, startTime = os.time() }
  log("  ✓ Craft accepted, monitoring...", C.grn)
  return true
end

-- Main check: iterate by priority, start one craft if needed
local function checkAndMaintain()
  if isAnyCraftActive() then
    local elapsed = os.time() - activeCraft.startTime
    log("⏳ Craft running: " .. activeCraft.entry.label ..
        " (Prio " .. (activeCraft.entry.priority or "?") ..
        ", " .. elapsed .. "s elapsed)", C.yel)
    return false
  end

  local allFull = true
  for _, entry in ipairs(stockList) do
    local stored = getStoredAmount(entry)
    local target = entry.target or 0
    local deficit = target - stored

    if CONFIG.verbose then
      local icon = stored >= target and "✓" or "✗"
      local col  = stored >= target and C.grn or C.red
      log(string.format("  %s [P%d] %-25s %s / %s", icon, entry.priority or 0,
          entry.label, fmtAmt(stored), fmtAmt(target)), col)
    end

    if deficit > 0 then
      allFull = false
      local cd = failCooldowns[entry.label]
      if cd and os.time() < cd then
        local remaining = cd - os.time()
        log("  ⏸ Cooldown: " .. entry.label .. " (" .. remaining .. "s remaining)", C.mag)
      elseif recentlyCrafted[entry.label] then
        log("  ⏸ Waiting for stock update: " .. entry.label .. " (crafted this cycle)", C.mag)
      elseif isCraftAlreadyRunning(entry) then
        log("  ⏳ Already crafting on AE2 CPU: " .. entry.label, C.yel)
      else
        failCooldowns[entry.label] = nil
        local craftable = getCraftable(entry)
        if craftable then
          if requestCraft(entry, craftable, deficit) then return false end
          log("  ↓ Trying next priority...", C.yel)
        else
          log("⚠ No craftable pattern found for: " .. entry.label ..
              " (check AE2 patterns & Fluid Discretizer)", C.yel)
        end
      end
    end
  end

  log(allFull and "✓ All plasmas at target level!" or
      "⚠ Some plasmas below target, but no crafts possible.",
      allFull and C.grn or C.yel)
  return allFull
end

-- Scan mode: show all plasma items/fluids in ME network
local function scanMode()
  print(C.cyn .. "=== SCAN: Fluids & Drops in ME Network ===" .. C.R)

  local function scanList(title, fetchFn, filterFn, formatFn)
    print("\n" .. C.yel .. "--- " .. title .. " ---" .. C.R)
    local ok, data = pcall(fetchFn)
    if not ok or not data then print("  Query failed."); return {} end
    local results = {}
    for _, v in ipairs(data) do if filterFn(v) then table.insert(results, v) end end
    table.sort(results, function(a, b) return (a.label or "") < (b.label or "") end)
    if #results > 0 then
      formatFn(results)
    else
      print("  No plasma entries found.")
    end
    return results
  end

  local fluids = scanList("getFluidsInNetwork() (Direct fluid query)",
    me.getFluidsInNetwork,
    function(f) return string.find(string.lower(f.label or ""), "plasma") end,
    function(r)
      print(string.format("  %-35s %-30s %-10s", "Label", "Name", "Amount"))
      print("  " .. string.rep("-", 78))
      for _, f in ipairs(r) do
        print(string.format("  %-35s %-30s %-10s", f.label or "?", f.name or "?", fmtAmt(f.amount or 0)))
      end
    end)

  local drops = scanList('getItemsInNetwork() (Fluid drops via Discretizer)',
    me.getItemsInNetwork,
    function(i)
      local l = string.lower(i.label or "")
      return string.find(l, "plasma") and (string.find(l, "drop of") or string.find(i.name or "", "fluid_drop"))
    end,
    function(r)
      print(string.format("  %-35s %-30s %-8s %-10s %-10s", "Label (for stockList)", "Name", "Damage", "Amount", "Craftable"))
      print("  " .. string.rep("-", 95))
      for _, i in ipairs(r) do
        print(string.format("  %-35s %-30s %-8d %-10s %-10s", i.label or "?", i.name or "?",
            i.damage or 0, fmtAmt(i.size or 0), i.isCraftable and "Yes" or "No"))
      end
    end)

  print("\n" .. C.cyn .. "=== NOTE ===" .. C.R)
  print('Both label formats work: "Helium Plasma" or "drop of Helium Plasma"')
  print("Amounts are in mB (1000 mB = 1 bucket).")
  if #fluids == 0 and #drops == 0 then
    print(C.red .. "\nWARNING: No plasmas found! Check Discretizer/adapter/storage." .. C.R)
  end
end

-- CLI argument handling
local args = {...}
if args[1] == "scan" then scanMode(); return end
if args[1] == "help" then
  print("Plasma Priority Maintainer for GTNH\n")
  print("Usage:")
  print("  plasma_maintainer        - Start the maintainer")
  print("  plasma_maintainer scan   - Show all plasma items in ME")
  print("  plasma_maintainer help   - This help\n")
  print("Config: Edit CONFIG table in script. Plasma list: /home/stockList.lua")
  print('Format: return { {label="Helium Plasma", target=1000, batch=1, priority=100}, ... }')
  return
end

-- Main loop
print(C.grn .. "Starting Plasma Priority Maintainer..." .. C.R)
print(C.yel .. "Press Ctrl+C to stop." .. C.R .. "\n")
local running = true
event.listen("interrupted", function() running = false end)

while running do
  recentlyCrafted = {}
  local allFull = false
  local ok, err = pcall(function()
    term.clear()
    print(C.cyn .. "╔══════════════════════════════════════════════════╗")
    print("║       PLASMA PRIORITY MAINTAINER v1.0            ║")
    print("╚══════════════════════════════════════════════════╝" .. C.R .. "\n")
    print(C.yel .. "Entries: " .. #stockList .. " | Interval: " .. CONFIG.checkInterval .. "s" .. C.R)
    print(string.rep("─", 55))
    allFull = checkAndMaintain()
  end)
  if not ok then log("ERROR: " .. tostring(err), C.red) end

  local sleepTime = allFull and CONFIG.idleSleepTime or CONFIG.checkInterval
  if allFull then log("💤 All full, sleeping " .. sleepTime .. "s...", C.grn) end

  local slept = 0
  while slept < sleepTime and running do
    os.sleep(1)
    slept = slept + 1
    if activeCraft then isAnyCraftActive() end
  end
end

print(C.grn .. "Plasma Maintainer stopped." .. C.R)
