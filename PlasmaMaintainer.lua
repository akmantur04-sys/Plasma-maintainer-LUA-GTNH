-- ============================================================
-- Plasma Priority Maintainer for GTNH OpenComputers
-- ============================================================
-- This script replaces the standard AE2 Level Maintainer and
-- provides priority-based plasma maintaining via OpenComputers.
-- Only 1 plasma is crafted at a time.
--
-- Features:
--   - Priority system (higher number = higher priority)
--   - Only 1 craft at a time to avoid CPU starvation
--   - Skips to next priority if craft fails (missing ingredients)
--   - Detects already running AE2 crafts (avoids duplicates)
--   - Idle sleep when all plasmas are at target level
--   - Fail cooldown to avoid spamming failed crafts
--   - Supports both "drop of X" and "X" label formats
--
-- Requirements:
--   - OpenComputers computer with adapter on ME Controller
--   - Fluid Discretizer in AE2 network (plasmas are represented
--     as items/drops and can be queried via OC)
--   - Patterns for the plasmas set up in AE2 network
--
-- Usage:
--   1. Edit stockList.lua (see below)
--   2. Start script: plasma_maintainer
--   3. Stop with Ctrl+Alt+C or Ctrl+C
--   4. Scan mode: plasma_maintainer scan
--   5. Help: plasma_maintainer help
-- ============================================================

local component = require("component")
local os = require("os")
local term = require("term")
local event = require("event")

-- Find ME Controller component
local me = component.me_controller

if not me then
  print("ERROR: No ME Controller found!")
  print("Make sure an adapter is connected to the ME Controller.")
  return
end

-- ============================================================
-- CONFIGURATION
-- ============================================================
local CONFIG = {
  -- How often (in seconds) stock levels are checked
  checkInterval = 10,

  -- How long (in seconds) to sleep when all plasmas are at target
  idleSleepTime = 60,

  -- If true, detailed logging is printed to screen
  verbose = true,

  -- Maximum number of concurrent crafts (1 = only 1 plasma at a time)
  maxConcurrentCrafts = 1,

  -- Timeout in seconds after which a craft is considered failed
  craftTimeout = 300,

  -- Cooldown in seconds before retrying a failed craft
  failCooldown = 30,

  -- Whether to prioritize higher-power CPUs for request() (true = strongest CPU first)
  prioritizePower = true,

  -- Optional: name of a specific crafting CPU (nil = automatic)
  cpuName = nil,
}

-- ============================================================
-- STOCK LIST
-- ============================================================
-- Load the stockList from a separate file, or use the embedded
-- list below as fallback.
--
-- Fields per entry:
--   label    = Display name of the plasma (as shown in AE2)
--   name     = Internal item name (e.g. "ae2fc:fluid_drop") (optional)
--   damage   = Metadata/damage value of the item (optional)
--   target   = Target amount to keep in system (in drops/mB)
--              1000 drops = 1 bucket. Supports scientific notation (e.g. 1e6)
--   batch    = How many to craft at once (1 recommended for plasma!)
--   priority = Higher number = higher priority (100 = highest)
--
-- IMPORTANT: With Fluid Discretizer, fluids are represented as items.
-- 1 drop = 1 mB. To maintain 1000mB (= 1 bucket) of plasma,
-- set target = 1000.
--
-- You can also use a separate file "stockList.lua".
-- Create a file that returns a table:
--   return { {label="...", target=..., batch=1, priority=100}, ... }
-- ============================================================

local stockList = nil

-- Try to load external stockList
local ok, result = pcall(dofile, "/home/stockList.lua")
if ok and type(result) == "table" then
  stockList = result
  print("Loaded stockList.lua with " .. #stockList .. " entries.")
else
  -- No external file found, use embedded list
  print("No stockList.lua found, using embedded list.")
  print("Create /home/stockList.lua for custom configuration.")
  print("")

  stockList = {
    -- =====================================================
    -- EXAMPLE ENTRIES - ADJUST THESE TO YOUR PLASMAS!
    -- =====================================================
    -- Use "scan" mode to find the exact label/name/damage
    -- values of your plasmas.
    --
    -- priority: higher number = crafted first
    -- batch: always 1 for plasma (expensive, craft one at a time)
    -- target: amount in mB to keep in system

    { label = "Helium Plasma",       target = 1000, batch = 1, priority = 100 },
    { label = "Nitrogen Plasma",     target = 1000, batch = 1, priority = 90 },
    { label = "Oxygen Plasma",       target = 1000, batch = 1, priority = 80 },
    { label = "Iron Plasma",         target = 1000, batch = 1, priority = 70 },
    { label = "Tin Plasma",          target = 1000, batch = 1, priority = 60 },
    { label = "Nickel Plasma",       target = 1000, batch = 1, priority = 50 },
    { label = "Bismuth Plasma",      target = 1000, batch = 1, priority = 40 },
    { label = "Calcium Plasma",      target = 1000, batch = 1, priority = 30 },
    { label = "Niobium Plasma",      target = 1000, batch = 1, priority = 20 },
    { label = "Titanium Plasma",     target = 1000, batch = 1, priority = 15 },
    { label = "Radon Plasma",        target = 1000, batch = 1, priority = 10 },
    { label = "Silver Plasma",       target = 1000, batch = 1, priority = 5 },

    -- Add more plasmas here...
  }
end

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Sort stockList by priority (highest number first = highest priority)
table.sort(stockList, function(a, b)
  return (a.priority or 0) > (b.priority or 0)
end)

-- Terminal color codes
local colors = {
  reset   = "\27[0m",
  red     = "\27[31m",
  green   = "\27[32m",
  yellow  = "\27[33m",
  blue    = "\27[34m",
  magenta = "\27[35m",
  cyan    = "\27[36m",
  white   = "\27[37m",
}

local function log(msg, color)
  if CONFIG.verbose then
    local c = color or colors.white
    local timestamp = os.date("%H:%M:%S")
    print(c .. "[" .. timestamp .. "] " .. msg .. colors.reset)
  end
end

local function formatAmount(amount)
  if amount >= 1000000 then
    return string.format("%.1fM mB", amount / 1000000)
  elseif amount >= 1000 then
    return string.format("%.1fK mB", amount / 1000)
  else
    return string.format("%d mB", amount)
  end
end

-- ============================================================
-- ITEM/FLUID QUERIES FROM ME NETWORK
-- ============================================================
-- IMPORTANT: With Fluid Discretizer, fluids are represented as items.
-- According to the GTNH Wiki:
--   - getItemsInNetwork(): label = "drop of <fluidname>"
--     (e.g. "drop of Helium Plasma"), amount in `size`
--   - getFluidsInNetwork(): label = "<fluidname>"
--     (e.g. "Helium Plasma"), amount in `amount`
--   - getCraftables(): label = "drop of <fluidname>"
--
-- This script tries BOTH methods and accepts both
-- "Helium Plasma" and "drop of Helium Plasma" in stockList.
-- ============================================================

--- Creates the "drop of" variant of a label
local function dropLabel(label)
  if string.sub(label, 1, 8) == "drop of " then
    return label  -- Already "drop of ..."
  end
  return "drop of " .. label
end

--- Removes "drop of " prefix if present
local function cleanLabel(label)
  if string.sub(label, 1, 8) == "drop of " then
    return string.sub(label, 9)
  end
  return label
end

--- Looks up a fluid/item in the ME network.
--- Tries getFluidsInNetwork first (direct fluid query),
--- then getItemsInNetwork (fluid drops via Discretizer).
--- @param entry table A stockList entry
--- @return number Current amount in system (mB), or 0
local function getStoredAmount(entry)
  local label = entry.label
  local labelClean = cleanLabel(label)
  local labelDrop = dropLabel(label)

  -- Method 1: getFluidsInNetwork() - direct fluid query
  -- Here label = fluid name (without "drop of")
  local ok, fluids = pcall(me.getFluidsInNetwork)
  if ok and fluids then
    for _, fluid in ipairs(fluids) do
      if fluid.label == labelClean then
        return fluid.amount or 0
      end
    end
  end

  -- Method 2: getItemsInNetwork() - fluid drops via Discretizer
  -- Here label = "drop of <fluidname>"
  local filter = {}
  if entry.name then
    filter.name = entry.name
  end
  if entry.damage then
    filter.damage = entry.damage
  end

  local items
  if next(filter) then
    items = me.getItemsInNetwork(filter)
  else
    -- Filter by "drop of" label to keep the query small (TPS-friendly)
    items = me.getItemsInNetwork({label = labelDrop})
  end

  if items then
    for _, item in ipairs(items) do
      if item.label == labelDrop or item.label == labelClean then
        return item.size or 0
      end
    end
  end

  -- Nothing found
  return 0
end

--- Checks if a fluid/item is craftable and returns the craftable object.
--- getCraftables() returns the "drop of" label for fluids.
--- @param entry table A stockList entry
--- @return table|nil The craftable object, or nil
local function getCraftable(entry)
  local label = entry.label
  local labelClean = cleanLabel(label)
  local labelDrop = dropLabel(label)

  local filter = {}
  if entry.name then
    filter.name = entry.name
  end
  if entry.damage then
    filter.damage = entry.damage
  end

  local craftables
  if next(filter) then
    craftables = me.getCraftables(filter)
  else
    -- Try filtering by "drop of" label first
    craftables = me.getCraftables({label = labelDrop})
    -- If nothing found, try unfiltered
    if not craftables or #craftables == 0 then
      craftables = me.getCraftables()
    end
  end

  if craftables then
    for _, craftable in ipairs(craftables) do
      local stack = craftable.getItemStack()
      if stack then
        -- Accept both "drop of X" and "X"
        if stack.label == labelDrop or
           stack.label == labelClean or
           stack.label == label then
          return craftable
        end
      end
    end
  end

  return nil
end

-- ============================================================
-- CRAFT TRACKING
-- ============================================================

local activeCraft = nil  -- { request = ..., entry = ..., startTime = ... }

-- Cooldown tracker: label -> timestamp when retry is allowed
local failCooldowns = {}

local function isAnyCraftActive()
  if activeCraft == nil then
    return false
  end

  local req = activeCraft.request

  -- Check if craft is done or failed
  if req.isDone() then
    log("✓ Craft done: " .. activeCraft.entry.label, colors.green)
    activeCraft = nil
    return false
  end

  if req.isCanceled() then
    log("✗ Craft canceled: " .. activeCraft.entry.label, colors.red)
    activeCraft = nil
    return false
  end

  if req.hasFailed() then
    log("✗ Craft failed: " .. activeCraft.entry.label, colors.red)
    -- Set cooldown to avoid immediate retry
    failCooldowns[activeCraft.entry.label] = os.time() + CONFIG.failCooldown
    activeCraft = nil
    return false
  end

  -- Timeout check
  local elapsed = os.time() - activeCraft.startTime
  if elapsed > CONFIG.craftTimeout then
    log("✗ Craft timeout: " .. activeCraft.entry.label, colors.red)
    failCooldowns[activeCraft.entry.label] = os.time() + CONFIG.failCooldown
    activeCraft = nil
    return false
  end

  return true
end

--- Checks if an AE2 craft is already running for this item
--- (not just our own, also externally started crafts)
local function isCraftAlreadyRunning(entry)
  -- Check if our own craft for this item is running
  if activeCraft and activeCraft.entry.label == entry.label then
    return true
  end

  -- Check AE2 crafting CPUs for an existing craft
  local ok, cpus = pcall(me.getCpus)
  if ok and cpus then
    local labelClean = cleanLabel(entry.label)
    local labelDrop = dropLabel(entry.label)
    for _, cpu in ipairs(cpus) do
      if cpu.busy then
        -- cpu.finalOutput contains the target item of the running craft
        local output = cpu.finalOutput
        if output then
          if output.label == labelClean or
             output.label == labelDrop or
             output.label == entry.label then
            return true
          end
        end
      end
    end
  end

  return false
end

-- ============================================================
-- MAIN LOGIC
-- ============================================================

local function requestCraft(entry, craftable, deficit)
  local amount = entry.batch or 1
  -- Don't craft more than needed
  if amount > deficit then
    amount = deficit
  end
  -- For plasma: always craft at least 1
  if amount < 1 then
    amount = 1
  end

  log("→ Starting craft: " .. amount .. "x " .. entry.label ..
      " (Prio " .. (entry.priority or "?") .. ")", colors.cyan)

  local request
  if CONFIG.cpuName then
    request = craftable.request(amount, CONFIG.prioritizePower, CONFIG.cpuName)
  else
    request = craftable.request(amount, CONFIG.prioritizePower)
  end

  if request then
    -- Wait briefly so AE2 can process the craft
    os.sleep(0.5)

    -- Check if craft failed immediately (missing ingredients)
    if request.hasFailed() then
      log("⚠ Craft failed immediately (missing ingredients?): " ..
          entry.label, colors.yellow)
      failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
      return false  -- Returns false → next priority will be tried
    end

    if request.isCanceled() then
      log("⚠ Craft canceled immediately: " .. entry.label, colors.yellow)
      failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
      return false
    end

    activeCraft = {
      request   = request,
      entry     = entry,
      startTime = os.time(),
    }
    return true
  else
    log("✗ Craft request failed for: " .. entry.label, colors.red)
    failCooldowns[entry.label] = os.time() + CONFIG.failCooldown
    return false  -- Try next priority
  end
end

--- Main function: checks all plasmas and starts a craft if needed.
--- @return boolean true if all plasmas are at target level
local function checkAndMaintain()
  -- If a craft is already running, wait
  if isAnyCraftActive() then
    log("⏳ Craft running: " .. activeCraft.entry.label ..
        " (Prio " .. (activeCraft.entry.priority or "?") .. ")", colors.yellow)
    return false
  end

  local allFull = true

  -- Iterate stockList by priority
  for _, entry in ipairs(stockList) do
    local stored = getStoredAmount(entry)
    local target = entry.target or 0
    local deficit = target - stored

    if CONFIG.verbose then
      local statusColor = stored >= target and colors.green or colors.red
      local statusIcon  = stored >= target and "✓" or "✗"
      log(string.format("  %s [P%d] %-25s %s / %s",
        statusIcon,
        entry.priority or 0,
        entry.label,
        formatAmount(stored),
        formatAmount(target)
      ), statusColor)
    end

    -- If below target
    if deficit > 0 then
      allFull = false

      -- Check cooldown (after failed craft)
      local cooldownUntil = failCooldowns[entry.label]
      if cooldownUntil and os.time() < cooldownUntil then
        log("  ⏸ Cooldown active for: " .. entry.label, colors.magenta)
        -- Don't break → continue to next priority!
        goto continue
      end
      -- Cooldown expired, clear it
      failCooldowns[entry.label] = nil

      -- Check if an AE2 craft is already running for this item
      if isCraftAlreadyRunning(entry) then
        log("  ⏳ Craft already running (AE2): " .. entry.label, colors.yellow)
        -- Don't break → continue to next priority!
        goto continue
      end

      local craftable = getCraftable(entry)
      if craftable then
        local success = requestCraft(entry, craftable, deficit)
        if success then
          return false  -- Craft started, not idle
        end
        -- success == false → craft failed (e.g. missing ingredients)
        -- Continue to next priority!
        log("  ↓ Trying next priority...", colors.yellow)
      else
        log("⚠ No pattern found for: " .. entry.label, colors.yellow)
      end
    end

    ::continue::
  end

  if allFull then
    log("✓ All plasmas at target level!", colors.green)
  else
    log("⚠ Some plasmas below target, but no crafts possible.", colors.yellow)
  end

  return allFull
end

-- ============================================================
-- SCAN MODE: Show all items/fluids in ME network
-- ============================================================

local function scanMode()
  print(colors.cyan .. "=== SCAN: Fluids & Drops in ME Network ===" .. colors.reset)
  print("")

  -- Method 1: getFluidsInNetwork()
  print(colors.yellow .. "--- getFluidsInNetwork() (Direct fluid query) ---" .. colors.reset)
  local ok, fluids = pcall(me.getFluidsInNetwork)
  local fluidCount = 0
  if ok and fluids then
    local plasmaFluids = {}
    for _, fluid in ipairs(fluids) do
      local labelLower = string.lower(fluid.label or "")
      if string.find(labelLower, "plasma") then
        table.insert(plasmaFluids, fluid)
      end
    end
    table.sort(plasmaFluids, function(a, b)
      return (a.label or "") < (b.label or "")
    end)
    if #plasmaFluids > 0 then
      print(string.format("  %-35s %-30s %-10s",
        "Label", "Name", "Amount"))
      print("  " .. string.rep("-", 78))
      for _, fluid in ipairs(plasmaFluids) do
        print(string.format("  %-35s %-30s %-10s",
          fluid.label or "?",
          fluid.name or "?",
          formatAmount(fluid.amount or 0)
        ))
      end
      fluidCount = #plasmaFluids
    else
      print("  No plasma fluids found.")
    end
  else
    print("  getFluidsInNetwork() failed or not available.")
  end

  print("")

  -- Method 2: getItemsInNetwork() - Fluid Drops
  print(colors.yellow .. "--- getItemsInNetwork() (Fluid drops via Discretizer) ---" .. colors.reset)
  print(colors.yellow .. '    Label format: "drop of <fluidname>"' .. colors.reset)
  local items = me.getItemsInNetwork()
  local plasmas = {}

  for _, item in ipairs(items) do
    local labelLower = string.lower(item.label or "")
    if string.find(labelLower, "plasma") and
       (string.find(labelLower, "drop of") or
        string.find(item.name or "", "fluid_drop")) then
      table.insert(plasmas, item)
    end
  end

  if #plasmas > 0 then
    table.sort(plasmas, function(a, b)
      return (a.label or "") < (b.label or "")
    end)
    print(string.format("  %-35s %-30s %-8s %-10s %-10s",
      "Label (for stockList)", "Name", "Damage", "Amount", "Craftable"))
    print("  " .. string.rep("-", 95))
    for _, item in ipairs(plasmas) do
      print(string.format("  %-35s %-30s %-8d %-10s %-10s",
        item.label or "?",
        item.name or "?",
        item.damage or 0,
        formatAmount(item.size or 0),
        item.isCraftable and "Yes" or "No"
      ))
    end
  else
    print("  No plasma drops found.")
    print("  Make sure a Fluid Discretizer is in the network.")
  end

  print("")
  print(colors.cyan .. "=== NOTE ===" .. colors.reset)
  print('You can use BOTH label formats in your stockList:')
  print('  label = "Helium Plasma"          -- script tries both')
  print('  label = "drop of Helium Plasma"  -- also works')
  print("")
  print("Amounts are in mB (1000 mB = 1 bucket).")
  if fluidCount == 0 and #plasmas == 0 then
    print("")
    print(colors.red .. "WARNING: No plasmas found!" .. colors.reset)
    print("Possible causes:")
    print("  - No Fluid Discretizer in network")
    print("  - No plasmas stored in system")
    print("  - Adapter not connected to ME Controller")
  end
end

-- ============================================================
-- STATUS DISPLAY
-- ============================================================

local function printStatus()
  term.clear()
  print(colors.cyan .. "╔══════════════════════════════════════════════════╗")
  print("║       PLASMA PRIORITY MAINTAINER v1.0            ║")
  print("╚══════════════════════════════════════════════════╝" .. colors.reset)
  print("")
  print(colors.yellow .. "Entries: " .. #stockList ..
        " | Interval: " .. CONFIG.checkInterval .. "s" ..
        " | Max Crafts: " .. CONFIG.maxConcurrentCrafts .. colors.reset)
  print(string.rep("─", 55))
end

-- ============================================================
-- MAIN PROGRAM
-- ============================================================

-- Check command line arguments
local args = {...}

if args[1] == "scan" then
  scanMode()
  return
end

if args[1] == "help" then
  print("Plasma Priority Maintainer for GTNH")
  print("")
  print("Usage:")
  print("  plasma_maintainer        - Start the maintainer")
  print("  plasma_maintainer scan   - Show all plasma items in ME")
  print("  plasma_maintainer help   - This help")
  print("")
  print("Configuration:")
  print("  Edit /home/stockList.lua for your plasma list.")
  print("  Edit the CONFIG table in this script for settings.")
  print("")
  print("stockList.lua format:")
  print('  return {')
  print('    { label = "Helium Plasma", target = 1000, batch = 1, priority = 100 },')
  print('    { label = "Iron Plasma",   target = 1000, batch = 1, priority = 50 },')
  print('    -- ...')
  print('  }')
  return
end

-- Main loop
print(colors.green .. "Starting Plasma Priority Maintainer..." .. colors.reset)
print(colors.yellow .. "Press Ctrl+C to stop." .. colors.reset)
print("")

local running = true

-- Register interrupt handler for clean shutdown
event.listen("interrupted", function()
  running = false
end)

while running do
  local allFull = false
  local ok, err = pcall(function()
    printStatus()
    allFull = checkAndMaintain()
  end)

  if not ok then
    log("ERROR: " .. tostring(err), colors.red)
  end

  -- Determine sleep duration
  local sleepTime = CONFIG.checkInterval
  if allFull then
    sleepTime = CONFIG.idleSleepTime
    log("💤 All full, sleeping " .. sleepTime .. "s...", colors.green)
  end

  -- Wait, but check regularly if we should stop
  local slept = 0
  while slept < sleepTime and running do
    os.sleep(1)
    slept = slept + 1
    -- Check if a running craft has finished
    if activeCraft then
      if not isAnyCraftActive() then
        -- Craft finished, start next check immediately
        break
      end
    end
  end
end

print(colors.green .. "Plasma Maintainer stopped." .. colors.reset)
