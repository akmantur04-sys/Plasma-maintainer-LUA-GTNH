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
  verbose         = true,  -- show craft decisions below status bar
  craftTimeout    = 3600,  -- seconds before timeout warning (0 = disabled)
  failCooldown    = 30,    -- seconds before retrying failed craft
  prioritizePower = true,  -- use strongest crafting CPU first
  cpuName         = nil,   -- specific crafting CPU name (nil = auto)
}

-- Load stock list
local ok, stockList = pcall(dofile, "/home/stockList.lua")
if not ok or type(stockList) ~= "table" then
  print("ERROR: Could not load /home/stockList.lua")
  print("Create it with: return { {label='Helium Plasma', target=1000, batch=1, priority=100}, ... }")
  return
end

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
  if n >= 1e6 then return string.format("%.1fM", n / 1e6)
  elseif n >= 1000 then return string.format("%.1fK", n / 1000)
  else return string.format("%.0f", n) end
end

-- Label helpers
local function dropLabel(l)  return l:sub(1,8) == "drop of " and l or ("drop of " .. l) end
local function cleanLabel(l) return l:sub(1,8) == "drop of " and l:sub(9) or l end
local function matchLabel(a, b) return b == a or b == cleanLabel(a) or b == dropLabel(a) end

local function buildFilter(entry)
  local f = {}
  if entry.name then f.name = entry.name end
  if entry.damage then f.damage = entry.damage end
  return f
end

-- Query stored amount from ME (tries fluids first, then items)
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

-- CPU helpers
local function getCpuInfo()
  local ok, cpus = pcall(me.getCpus)
  if not ok or not cpus then return 0, 0 end
  local busy = 0
  for _, cpu in ipairs(cpus) do if cpu.busy then busy = busy + 1 end end
  return #cpus, busy
end

-- Craft tracking: label -> { request, entry, startTime }
local activeCrafts = {}
local failCooldowns = {}
local recentlyCrafted = {}

local function finishCraft(label, msg, color, setCooldown)
  local craft = activeCrafts[label]
  if not craft then return end
  local elapsed = os.time() - craft.startTime
  log(msg .. label .. " (after " .. string.format("%.0f", elapsed) .. "s)", color)
  recentlyCrafted[label] = true
  if setCooldown then
    failCooldowns[label] = os.time() + CONFIG.failCooldown
    log("  ⏸ Cooldown: " .. CONFIG.failCooldown .. "s before retry", C.mag)
  end
  activeCrafts[label] = nil
end

-- Check if AE2 is already crafting this item (our craft or external)
local function isCraftAlreadyRunning(entry)
  if activeCrafts[entry.label] then return true end
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

-- Update all active crafts: check status, clean up finished ones
local function updateActiveCrafts()
  for label, craft in pairs(activeCrafts) do
    local req = craft.request
    if req.isDone()     then finishCraft(label, "✓ Done: ", C.grn, false)
    elseif req.isCanceled() then finishCraft(label, "✗ Canceled: ", C.red, false)
    elseif req.hasFailed()  then finishCraft(label, "✗ Failed: ", C.red, true)
    elseif CONFIG.craftTimeout > 0 and os.time() - craft.startTime > CONFIG.craftTimeout then
      if isCraftAlreadyRunning(craft.entry) then
        local elapsed = os.time() - craft.startTime
        if elapsed % 60 < CONFIG.checkInterval then
          log("⚠ Exceeds timeout but still on CPU: " .. label ..
              " (" .. string.format("%.0f", elapsed) .. "s)", C.yel)
        end
      else
        finishCraft(label, "✗ Timeout (craft lost): ", C.red, true)
      end
    end
  end
end

local function countActiveCrafts()
  local n = 0
  for _ in pairs(activeCrafts) do n = n + 1 end
  return n
end

local function requestCraft(entry, craftable, deficit)
  local amount = math.min(entry.batch or 1, deficit)
  local total, busy = getCpuInfo()
  log("→ Craft: " .. fmtAmt(amount) .. "x " .. entry.label ..
      " (P" .. (entry.priority or "?") .. ") [CPUs: " .. busy .. "/" .. total .. "]", C.cyn)

  local req = CONFIG.cpuName
    and craftable.request(amount, CONFIG.prioritizePower, CONFIG.cpuName)
    or  craftable.request(amount, CONFIG.prioritizePower)

  if not req then
    log("  ✗ Request returned nil (AE2 error or broken pattern)", C.red)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false
  end

  os.sleep(0.5)

  if req.hasFailed() then
    log("  ⚠ Failed: missing ingredients or circular dependency", C.yel)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false
  end
  if req.isCanceled() then
    log("  ⚠ Canceled: CPU may have been taken", C.yel)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false
  end

  activeCrafts[entry.label] = { request = req, entry = entry, startTime = os.time() }
  log("  ✓ Accepted, monitoring...", C.grn)
  return true
end

-- ============================================================
-- DISPLAY: Compact status bar + craft decisions
-- ============================================================

-- Collect all stock levels in one pass (returns table of {entry, stored, target, deficit})
local function collectStatus()
  local status = {}
  for _, entry in ipairs(stockList) do
    local stored = getStoredAmount(entry)
    local target = entry.target or 0
    table.insert(status, {
      entry   = entry,
      stored  = stored,
      target  = target,
      deficit = target - stored,
    })
  end
  return status
end

-- Print compact status bar: one line per plasma, colored
local function printStatusBar(status, cpuTotal, cpuBusy)
  term.clear()
  print(C.cyn .. "══ PLASMA MAINTAINER ══" .. C.R ..
        "  Entries: " .. #stockList ..
        "  Interval: " .. CONFIG.checkInterval .. "s" ..
        "  CPUs: " .. cpuBusy .. "/" .. cpuTotal)
  print(string.rep("─", 60))

  -- Compact grid: "Label: amount/target" with color
  for _, s in ipairs(status) do
    local pct = s.target > 0 and (s.stored / s.target * 100) or 100
    local col = pct >= 100 and C.grn or (pct >= 50 and C.yel or C.red)
    local bar = col .. string.format(" P%-3s %-22s %8s / %-8s",
        tostring(s.entry.priority or 0), s.entry.label,
        fmtAmt(s.stored), fmtAmt(s.target))

    -- Show percentage or checkmark
    if pct >= 100 then
      bar = bar .. "  ✓"
    else
      bar = bar .. string.format(" %.0f%%", pct)
    end
    print(bar .. C.R)
  end

  print(string.rep("─", 60))

  -- Show active crafts in header area
  for label, craft in pairs(activeCrafts) do
    local elapsed = os.time() - craft.startTime
    print(C.cyn .. "⏳ Crafting: " .. label ..
          " (P" .. (craft.entry.priority or "?") ..
          ", " .. string.format("%.0f", elapsed) .. "s)" .. C.R)
  end
end

-- ============================================================
-- MAIN CHECK LOGIC
-- ============================================================

local function checkAndMaintain()
  -- Update all active crafts (check done/failed/canceled)
  updateActiveCrafts()

  -- Check CPU availability
  local cpuTotal, cpuBusy = getCpuInfo()
  local cpuFree = cpuTotal - cpuBusy

  -- Collect all stock levels (one pass for display)
  local status = collectStatus()

  -- Display compact status bar
  printStatusBar(status, cpuTotal, cpuBusy)

  -- Determine if all full
  local allFull = true
  for _, s in ipairs(status) do
    if s.deficit > 0 then allFull = false; break end
  end

  if allFull then
    log("✓ All plasmas at target!", C.grn)
    return true
  end

  if cpuFree <= 0 then
    log("⏳ All CPUs busy (" .. cpuBusy .. "/" .. cpuTotal .. "), waiting...", C.yel)
    return false
  end

  -- Try to start crafts for free CPUs (iterate by priority)
  local craftsStarted = 0
  for _, s in ipairs(status) do
    if cpuFree <= 0 then break end  -- no more free CPUs
    if s.deficit <= 0 then goto next end

    local label = s.entry.label
    local cd = failCooldowns[label]
    if cd and os.time() < cd then
      log("  ⏸ Cooldown: " .. label .. " (" .. string.format("%.0f", cd - os.time()) .. "s)", C.mag)
      goto next
    end
    if recentlyCrafted[label] then
      log("  ⏸ Stock update pending: " .. label, C.mag)
      goto next
    end
    if isCraftAlreadyRunning(s.entry) then
      log("  ⏳ Already on CPU: " .. label, C.yel)
      goto next
    end

    failCooldowns[label] = nil
    local craftable = getCraftable(s.entry)
    if craftable then
      if requestCraft(s.entry, craftable, s.deficit) then
        craftsStarted = craftsStarted + 1
        cpuFree = cpuFree - 1
      else
        log("  ↓ Next priority...", C.yel)
      end
    else
      log("  ⚠ No pattern: " .. label, C.yel)
    end

    ::next::
  end

  if craftsStarted == 0 and countActiveCrafts() == 0 then
    log("⚠ Below target, but no crafts possible.", C.yel)
  end
  return false
end

-- ============================================================
-- SCAN MODE
-- ============================================================

local function scanMode()
  print(C.cyn .. "=== SCAN: Fluids & Drops in ME Network ===" .. C.R)

  local function scanList(title, fetchFn, filterFn, formatFn)
    print("\n" .. C.yel .. "--- " .. title .. " ---" .. C.R)
    local ok, data = pcall(fetchFn)
    if not ok or not data then print("  Query failed."); return {} end
    local results = {}
    for _, v in ipairs(data) do if filterFn(v) then table.insert(results, v) end end
    table.sort(results, function(a, b) return (a.label or "") < (b.label or "") end)
    if #results > 0 then formatFn(results)
    else print("  No plasma entries found.") end
    return results
  end

  local fluids = scanList("getFluidsInNetwork()",
    me.getFluidsInNetwork,
    function(f) return string.find(string.lower(f.label or ""), "plasma") end,
    function(r)
      print(string.format("  %-35s %-30s %-10s", "Label", "Name", "Amount"))
      print("  " .. string.rep("-", 78))
      for _, f in ipairs(r) do
        print(string.format("  %-35s %-30s %-10s", f.label or "?", f.name or "?", fmtAmt(f.amount or 0)))
      end
    end)

  local drops = scanList("getItemsInNetwork()",
    me.getItemsInNetwork,
    function(i)
      local l = string.lower(i.label or "")
      return string.find(l, "plasma") and (string.find(l, "drop of") or string.find(i.name or "", "fluid_drop"))
    end,
    function(r)
      print(string.format("  %-35s %-30s %-8s %-10s %-10s", "Label", "Name", "Dmg", "Amount", "Craft?"))
      print("  " .. string.rep("-", 95))
      for _, i in ipairs(r) do
        print(string.format("  %-35s %-30s %-8s %-10s %-10s", i.label or "?", i.name or "?",
            tostring(i.damage or 0), fmtAmt(i.size or 0), i.isCraftable and "Yes" or "No"))
      end
    end)

  print("\n" .. C.cyn .. "NOTE: " .. C.R .. 'Both "Helium Plasma" and "drop of Helium Plasma" work.')
  print("Amounts in mB (1000 = 1 bucket).")
  if #fluids == 0 and #drops == 0 then
    print(C.red .. "WARNING: No plasmas found! Check Discretizer/adapter/storage." .. C.R)
  end
end

-- ============================================================
-- CLI & MAIN LOOP
-- ============================================================

local args = {...}
if args[1] == "scan" then scanMode(); return end
if args[1] == "help" then
  print("Plasma Priority Maintainer for GTNH\n")
  print("  plasma_maintainer        Start maintainer")
  print("  plasma_maintainer scan   Show plasma items in ME")
  print("  plasma_maintainer help   This help\n")
  print("Config: CONFIG table in script. Plasmas: /home/stockList.lua")
  print('Format: return { {label="Helium Plasma", target=1000, batch=1, priority=100}, ... }')
  return
end

print(C.grn .. "Starting Plasma Priority Maintainer..." .. C.R)
print(C.yel .. "Press Ctrl+C to stop.\n" .. C.R)
local running = true
event.listen("interrupted", function() running = false end)

while running do
  recentlyCrafted = {}
  local allFull = false
  local ok, err = pcall(function() allFull = checkAndMaintain() end)
  if not ok then log("ERROR: " .. tostring(err), C.red) end

  local sleepTime = allFull and CONFIG.idleSleepTime or CONFIG.checkInterval
  if allFull then log("💤 Sleeping " .. sleepTime .. "s...", C.grn) end

  local slept = 0
  while slept < sleepTime and running do
    os.sleep(1)
    slept = slept + 1
    if next(activeCrafts) then updateActiveCrafts() end
  end
end

print(C.grn .. "Plasma Maintainer stopped." .. C.R)
