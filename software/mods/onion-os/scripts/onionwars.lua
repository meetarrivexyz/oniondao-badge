-- OnionWars (Chicago, 2025) -- formerly "Drugwars: Onion Edition"
-- A badge-native, onion-themed take on the classic trading game, set in 2025
-- Chicago and played in SOLANA. Onions are priced in US dollars; you pay for
-- them with SOL at the day's exchange rate. That rate tracks Solana's real 2025
-- price arc over 30 days (Jan open ~$189, ATH $295, March dip $125, a fall
-- rally to ~$248, then a December close near $125), so timing matters: hold SOL
-- when it's about to rip, hold onions when it's about to dump.
--
-- Buy low, sell high across six neighborhoods; pay off the Coinbase margin loan
-- (Brian Armstrong is your broker) before the interest buries you; dodge
-- Pritzker raids, FBI onion seizures, and shakedowns; upgrade your cart at the
-- Lincoln Park store; and build the biggest net worth to become the Onion
-- Kingpin. The in-game SOL and USD balances are an in-game ledger saved to NVS,
-- NOT real on-chain transfers.
--
-- STAKED MATCH (parked, STAKING_ENABLED=false): entering would cost real onions
-- settled server-side -- see software/mods/onion-os/ONIONWARS.md. The ONLINE
-- hooks at the bottom of this file only ever report score; in free play the
-- game makes no network calls at all.
--
-- Controls:
--   UP / DOWN     move the cursor / change quantity by 1
--   LEFT / RIGHT  change quantity by 10 (and page where noted)
--   SELECT        confirm the highlighted action
--   CANCEL        back out one screen / (on main menu) save and exit

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local TOTAL_DAYS   = 30   -- the 2025 trading year, 30 days / 30 moves
local START_SOL    = 5000     -- starting wallet in milli-SOL (5.00 SOL)
local START_DEBT   = 150000   -- starting Coinbase margin loan in USD cents ($1,500)
local START_HP     = 30
local START_COAT   = 100      -- carrying capacity, in pounds of onions
local DEBT_RATE    = 0.08     -- Coinbase margin "juice": 8%/day, compounds daily
local GOAL_NET     = 2500000  -- the "retire" target in USD cents: $25,000 = Onion Kingpin
local SCREEN_W      = 264
local SCREEN_H      = 176

-- Difficulty / fairness knobs. Higher = more punishing. Defaults are tuned so a
-- careful player can recover from a bad break: at most ONE bad event per travel,
-- a grace window at the start, gentler raid odds, and smaller, rarer shakedowns.
local GRACE_DAYS    = 3    -- first N days have no raids or shakedowns
local RAID_BASE     = 6    -- base Pritzker-raid % while carrying onions
local RAID_PER_UNIT = 20   -- +1% raid risk per this many pounds carried
local RAID_CAP      = 25   -- max raid %
local POLICY_CHANCE = 10   -- % chance of a policy/tax skim on a travel
local POLICY_MIN    = 6    -- a policy skim takes POLICY_MIN..POLICY_MAX % of your SOL
local POLICY_MAX    = 15
local FBI_CHANCE    = 8    -- % chance the FBI confiscates carried onions on a travel
local FBI_MIN       = 20   -- the FBI seizes FBI_MIN..FBI_MAX % of carried onions
local FBI_MAX       = 40
local SHAKE_CHANCE  = 7    -- % chance EACH of the Jiaming / Tippi shakedowns
local SHAKEDOWN_PCT = 12   -- % taken by a shakedown
local PD_GAMEOVER   = 8    -- public defender: % chance you're held for good
local RUN_ESCAPE    = 80   -- ditch-and-run: % chance of a clean getaway

-- Master switch for real-onion staking. While false, the game is pure free
-- play: no entry fee, no score reporting -- nothing ever touches the wallet,
-- regardless of any ow_match key. Flip to true once the server-side match
-- routes are live (see ONIONWARS.md).
local STAKING_ENABLED = false

-- Staked-match economics (real onions; settled server-side, see ONIONWARS.md).
local ENTRY_FEE  = 100
local WINNER_PCT = 80
local TAX_PCT    = 20
local TAX_HANDLE = "@chicagotax"
local POT_HANDLE = "onionwars"
local API_BASE   = "https://oniondao.dev"

-- Lincoln Park cart-upgrade store. Each upgrade adds CART_UPGRADE pounds of
-- capacity. Priced in USD (paid in SOL) and rising every time, so capacity is a
-- real money sink. (The cheap random "supplier" cart event still happens on the
-- road; this is the reliable but expensive option.)
local CART_CITY      = "Lincoln Park"
local CART_UPGRADE   = 10     -- pounds added per store upgrade
local CART_BASE_COST = 40000  -- price of your first store upgrade in USD cents ($400)...
local CART_COST_STEP = 20000  -- ...rising by $200 for each one already bought

-- Solana price model. S.sol_price is the USD-per-SOL price in CENTS. It tracks
-- Solana's real 2025 arc through these keyframes (day -> cents), linearly
-- interpolated with a little daily jitter. 30 days == the 2025 trading year.
local SOL_OPEN = 18923   -- Jan 2025 open, $189.23 (also the fresh-run price)
local SOL_MIN  = 11000   -- clamp floor (a hair below the March low)
local SOL_MAX  = 31000   -- clamp ceiling (a hair above the Jan ATH)
local SOL_KEYS = {
  { 1,  18923 },  -- Jan open    $189.23
  { 2,  29500 },  -- Jan ATH     $295.00
  { 3,  23890 },  -- Jan close   $238.90
  { 7,  12466 },  -- March dip   $124.66 (Q1 low)
  { 17, 18263 },  -- July end    $182.63
  { 22, 24762 },  -- Sept rally  $247.62
  { 30, 12492 },  -- Dec close   $124.92
}

-- The onions you trade, in 2025 retail terms (USD/lb), cheapest -> priciest.
-- name, base $/lb (cents), low price (cents), high price (cents). The table
-- order maps to saved inventory slots, so keep it stable across updates.
-- (Internally the list is still iterated as the goods list.)
local DRUGS = {
  { name = "Green Onions", base = 99,  low = 60,  high = 160 },
  { name = "Yellow Onion", base = 150, low = 90,  high = 240 },
  { name = "White Onion",  base = 160, low = 100, high = 260 },
  { name = "Red Onion",    base = 180, low = 110, high = 290 },
  { name = "Sweet Onion",  base = 200, low = 120, high = 320 },
  { name = "Vidalia",      base = 250, low = 150, high = 400 },  -- Vidalia/Walla Walla
  { name = "Cipollini",    base = 350, low = 200, high = 600 },  -- seasonal
  { name = "Shallots",     base = 500, low = 300, high = 850 },  -- priciest
}

local CITIES = {
  "The Loop",
  "South Side",
  "West Side",
  "Wicker Park",
  "Englewood",
  "Lincoln Park",
}
local BANK_CITY = "The Loop"  -- Coinbase + Brian Armstrong live here (OnionDAO HQ)

-- Per-neighborhood price level, indexed to match CITIES. Onions cost more in
-- affluent areas and less in rougher ones, so buy cheap (Englewood/South Side)
-- and sell high (Lincoln Park/The Loop). Applied to every market price.
local CITY_MULT = {
  1.15,  -- The Loop      (downtown, pricey)
  0.85,  -- South Side
  0.90,  -- West Side
  1.10,  -- Wicker Park   (trendy)
  0.80,  -- Englewood     (cheapest)
  1.25,  -- Lincoln Park  (most affluent)
}

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local S -- the live game state table

local function fresh_state()
  local inv = {}
  for i = 1, #DRUGS do inv[i] = 0 end
  return {
    day      = 1,
    city     = 1,                 -- index into CITIES
    sol      = START_SOL,         -- wallet, in milli-SOL
    debt     = START_DEBT,        -- Coinbase margin loan, in USD cents
    hp       = START_HP,
    coat     = START_COAT,        -- carrying capacity, in pounds
    gun      = 0,                 -- number of lawyers on retainer
    inv      = inv,               -- pounds held per onion index
    market   = {},                -- USD-cents price per onion for current city (0 = unavailable)
    sol_price = SOL_OPEN,         -- current USD-per-SOL price, in cents
    cart_lvl = 0,                 -- store cart upgrades bought (sets next price)
    over     = false,
    peak     = 0,                 -- best net worth (USD cents) seen this run (runtime only)
    tip      = nil,               -- pending hot-tip { good, city } (runtime only)
  }
end

-- pounds currently carried
local function carried()
  local n = 0
  for i = 1, #DRUGS do n = n + S.inv[i] end
  return n
end

local function space_left()
  return S.coat - carried()
end

-------------------------------------------------------------------------------
-- Currency conversion (SOL wallet <-> USD prices)
-------------------------------------------------------------------------------

-- USD cents -> milli-SOL at the current price.
local function usd_to_msol(cents)
  return math.floor(cents * 1000 / S.sol_price + 0.5)
end

-- milli-SOL -> USD cents at the current price.
local function msol_to_usd(msol)
  return math.floor(msol * S.sol_price / 1000 + 0.5)
end

-- USD value (cents) of the onions you're holding, at base retail price so the
-- figure is stable even where a good isn't on sale today.
local function stash_value()
  local v = 0
  for i = 1, #DRUGS do v = v + S.inv[i] * DRUGS[i].base end
  return v
end

-- Net worth in USD cents: SOL wallet + held onions - margin loan.
local function net_worth()
  return msol_to_usd(S.sol) + stash_value() - S.debt
end

-- Rank ladder by net worth (USD cents) -- a title to chase. Rises to GOAL_NET.
local TITLES = {
  { -1,      "Broke" },           -- in the red (debt > assets)
  { 0,       "Onion Peddler" },
  { 300000,  "Onion Hustler" },   -- $3,000
  { 800000,  "Onion Dealer" },    -- $8,000
  { 1500000, "Onion Boss" },      -- $15,000
  { 2000000, "Onion Baron" },     -- $20,000
  { GOAL_NET, "Onion Kingpin" },  -- $25,000
}
local function rank_title(nw)
  local t = TITLES[1][2]
  for _, row in ipairs(TITLES) do
    if nw >= row[1] then t = row[2] end
  end
  return t
end

-------------------------------------------------------------------------------
-- Save / load (single compact NVS key, kv_set value limit is ~1024 bytes)
-------------------------------------------------------------------------------

local SAVE_KEY = "ow_save3"  -- bumped for the SOL/USD economy; old saves discarded

local function serialize()
  -- flat, order-stable:
  -- day|city|sol|debt|hp|coat|gun|over|inv0,inv1,...|sol_price|cart_lvl
  local parts = {
    S.day, S.city, S.sol, S.debt, S.hp, S.coat, S.gun,
    S.over and 1 or 0,
  }
  local inv = {}
  for i = 1, #DRUGS do inv[i] = tostring(S.inv[i]) end
  return table.concat(parts, "|") .. "|" .. table.concat(inv, ",")
    .. "|" .. S.sol_price .. "|" .. S.cart_lvl
end

local function deserialize(blob)
  local fields = {}
  for f in string.gmatch(blob, "([^|]+)") do fields[#fields + 1] = f end
  if #fields < 9 then return nil end
  local st = fresh_state()
  st.day  = tonumber(fields[1]) or 1
  st.city = tonumber(fields[2]) or 1
  st.sol  = tonumber(fields[3]) or START_SOL
  st.debt = tonumber(fields[4]) or START_DEBT
  st.hp   = tonumber(fields[5]) or START_HP
  st.coat = tonumber(fields[6]) or START_COAT
  st.gun  = tonumber(fields[7]) or 0
  st.over = (tonumber(fields[8]) or 0) == 1
  local idx = 1
  for u in string.gmatch(fields[9], "([^,]+)") do
    st.inv[idx] = tonumber(u) or 0
    idx = idx + 1
  end
  st.sol_price = tonumber(fields[10]) or SOL_OPEN
  st.cart_lvl  = tonumber(fields[11]) or 0
  return st
end

local function save_game()
  if onion.kv_set then onion.kv_set(SAVE_KEY, serialize()) end
end

local function load_game()
  if not onion.kv_get then return nil end
  local blob = onion.kv_get(SAVE_KEY)
  if not blob or blob == "" then return nil end
  return deserialize(blob)
end

local function clear_save()
  if onion.kv_delete then onion.kv_delete(SAVE_KEY)
  elseif onion.kv_set then onion.kv_set(SAVE_KEY, "") end
end

-------------------------------------------------------------------------------
-- Randomness
-------------------------------------------------------------------------------

-- Seed from badge uptime; mix in secure_random when available for a better seed.
local function seed_rng()
  local seed = onion.millis and onion.millis() or 1
  if onion.secure_random then
    local r = onion.secure_random(4)
    if r and #r >= 4 then
      seed = seed ~ ((r:byte(1) << 24) | (r:byte(2) << 16) | (r:byte(3) << 8) | r:byte(4))
    end
  end
  math.randomseed(seed & 0x7fffffff)
  for _ = 1, 8 do math.random() end -- warm up
end

local function rnd(a, b) return math.random(a, b) end
local function chance(pct) return math.random(100) <= pct end

-------------------------------------------------------------------------------
-- Formatting / drawing helpers
-------------------------------------------------------------------------------

-- 12345 -> "12,345"
local function commas(n)
  n = math.floor(n + 0.5)
  local sign = n < 0 and "-" or ""
  local s = tostring(math.abs(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  out = out:gsub("^,", "")
  return sign .. out
end

-- USD cents -> "$1,234.56"
local function usd(cents)
  cents = math.floor(cents + 0.5)
  local neg = cents < 0
  cents = math.abs(cents)
  local dollars = math.floor(cents / 100)
  return (neg and "-$" or "$") .. commas(dollars) .. string.format(".%02d", cents % 100)
end

-- whole-dollar form for tight lines, "$1,234"
local function usd0(cents)
  return "$" .. commas(math.floor((cents + 50) / 100))
end

-- milli-SOL -> "5.00 SOL"
local function sol_str(msol)
  return string.format("%.2f", msol / 1000) .. " SOL"
end

-- Layout constants for the 264x176 e-paper panel using FreeMono9pt fonts.
-- The 9pt mono font advances ~18px per line and ~11px per char, so lines must
-- be >=18px apart and <=22 chars wide, and at most ~9 lines fit top to bottom.
local LH       = 18    -- line height (font is FreeMono9pt, ~18px tall)
local TOP_Y    = 16    -- baseline of the first line
local MAX_CHARS = 22   -- safe characters per line at x=6

-- Draw a full screen in one batched e-paper refresh. Unless opts.no_header is
-- set, a persistent SOL wallet line (with USD value) is drawn at the top of
-- every screen so the player always sees their spendable Solana.
local function screen(lines, opts)
  opts = opts or {}
  local x  = opts.x or 6
  local y  = opts.y or TOP_Y
  local lh = opts.lh or LH
  local font = opts.font or "small"
  local out = lines
  if S and S.sol and not opts.no_header then
    out = { sol_str(S.sol) .. "  " .. usd0(msol_to_usd(S.sol)) }
    for _, l in ipairs(lines) do out[#out + 1] = l end
  end
  if onion.display_begin then
    onion.display_begin()
    onion.display_lines(out, x, y, lh, { clear = true, font = font })
    onion.display_commit()
  else
    onion.display_lines(out, x, y, lh, { clear = true, font = font })
  end
end

-- A blocking message screen: shows lines, waits for SELECT or CANCEL. Pass
-- opts.no_header to drop the persistent wallet line (used by money-summary
-- screens that already show net worth, to claw back a line on the 9-line panel).
local function notify(lines, opts)
  opts = opts or {}
  local rows = {}
  for _, l in ipairs(lines) do rows[#rows + 1] = l end
  rows[#rows + 1] = ""
  rows[#rows + 1] = "[SELECT] continue"
  screen(rows, { font = "small", no_header = opts.no_header })
  local last = onion.buttons()
  while true do
    local b = onion.buttons()
    if (b.select and not last.select) or (b.cancel and not last.cancel) then
      return
    end
    last = b
    onion.sleep(60)
  end
end

-- Wait for a fresh press of any button in `names`; returns the name pressed.
-- Edge-detected against the previous frame. CANCEL is always honored.
local function wait_button(prev)
  while true do
    local b = onion.buttons()
    for _, name in ipairs({ "up", "down", "left", "right", "select", "cancel" }) do
      if b[name] and not prev[name] then
        prev.up, prev.down, prev.left, prev.right, prev.select, prev.cancel =
          b.up, b.down, b.left, b.right, b.select, b.cancel
        return name, b
      end
    end
    prev.up, prev.down, prev.left, prev.right, prev.select, prev.cancel =
      b.up, b.down, b.left, b.right, b.select, b.cancel
    onion.sleep(50)
  end
end

-------------------------------------------------------------------------------
-- Market generation
-------------------------------------------------------------------------------

-- Build the current city's market: each onion has a chance to be on sale at a
-- random USD price in its range. Returns event text lines (price shocks) if any.
local function generate_market()
  local events = {}
  local mult = CITY_MULT[S.city] or 1.0
  S.market = {}
  for i, d in ipairs(DRUGS) do
    if chance(80) then
      S.market[i] = math.max(1, math.floor(rnd(d.low, d.high) * mult))
    else
      S.market[i] = 0 -- not available here today
    end
  end

  -- Occasional price shocks make some runs lucrative.
  if chance(18) then
    -- Demand spike: price spikes WAY up.
    local i = rnd(1, #DRUGS)
    S.market[i] = math.floor(DRUGS[i].high * (1.5 + math.random()) * mult)
    local n = DRUGS[i].name
    local up = {
      { "Viral TikTok demand!", n .. " soaring!" },
      { "Foodies pay a premium!", n .. " is hot!" },
      { "Restaurant week hits!", n .. " up big!" },
      { "Kennedy: a superfood!", n .. " soars!" },
    }
    local m = up[rnd(1, #up)]
    events[#events + 1] = m[1]; events[#events + 1] = m[2]
  elseif chance(18) then
    -- Glut: price crashes WAY down.
    local i = rnd(1, #DRUGS)
    S.market[i] = math.max(1, math.floor(DRUGS[i].low / 3 * mult))
    local n = DRUGS[i].name
    local down = {
      { "FDA recall flood!", n .. " cheap!" },
      { "Cook County auction!", n .. " crashes!" },
      { "Bumper harvest!", n .. " glut!" },
    }
    local m = down[rnd(1, #down)]
    events[#events + 1] = m[1]; events[#events + 1] = m[2]
  end

  -- Hot tip pays off: if a tip pointed you to this city, the named good is hot
  -- here today. This makes a tip actionable -- travel here to cash in. Consumes it.
  if S.tip and S.tip.city == S.city then
    local i = S.tip.good
    S.market[i] = math.floor(DRUGS[i].high * (1.4 + math.random()) * mult)
    events[#events + 1] = "Your tip paid off!"
    events[#events + 1] = DRUGS[i].name .. " is hot here!"
    S.tip = nil
  end

  return events
end

-------------------------------------------------------------------------------
-- Solana price arc (tracks Solana's real 2025 year over the 30 days)
-------------------------------------------------------------------------------

-- Linearly-interpolated USD-per-SOL price (cents) for a given day, from SOL_KEYS.
local function sol_curve(day)
  if day <= SOL_KEYS[1][1] then return SOL_KEYS[1][2] end
  for i = 2, #SOL_KEYS do
    local a, b = SOL_KEYS[i - 1], SOL_KEYS[i]
    if day <= b[1] then
      local t = (day - a[1]) / (b[1] - a[1])
      return math.floor(a[2] + (b[2] - a[2]) * t + 0.5)
    end
  end
  return SOL_KEYS[#SOL_KEYS][2]
end

-- Set the SOL price for the current day: the curve value plus a little jitter
-- (+-4%) so the chart isn't a perfectly straight line. Clamped to the year band.
local function set_sol_for_day()
  local base = sol_curve(S.day)
  local jitter = (rnd(0, 8) - 4) / 100
  local p = math.floor(base * (1 + jitter) + 0.5)
  if p < SOL_MIN then p = SOL_MIN end
  if p > SOL_MAX then p = SOL_MAX end
  S.sol_price = p
end

-------------------------------------------------------------------------------
-- Random travel events
-------------------------------------------------------------------------------

-- Spend `days` locked up: time passes (the margin loan keeps compounding and the
-- SOL price keeps moving) while you can't trade. If this runs past the deadline,
-- do_travel ends the game on its day check.
local function jail(days)
  for _ = 1, days do
    S.day = S.day + 1
    S.debt = math.floor(S.debt * (1 + DEBT_RATE))
    set_sol_for_day()
  end
end

-- A JB Pritzker Law raid (the Governor's digital-asset crackdown). You're caught
-- mid onion buy and choose a defense -- a tradeoff of MONEY (SOL) vs DAYS:
--   Super lawyer: high SOL, 0 days, keep onions, always wins.
--   Bob (cheap):  mid SOL, 2 days in jail, keep onions.
--   Public defender: free, 2-4 days in jail, keep onions; small chance held for good.
--   Ditch cart & run: free + 0 days, but you drop ALL your onions; sometimes caught.
-- A lawyer on retainer (S.gun, bought from a lobbyist) is a free instant win.
local function raid_encounter()
  local super_cost = math.max(200, math.floor(S.sol * 0.40))
  local bob_cost   = math.max(100, math.floor(S.sol * 0.20))
  local opts = {}
  if S.gun > 0 then opts[#opts + 1] = { k = "retainer", label = "Use retainer (free)" } end
  opts[#opts + 1] = { k = "super",  label = "Top lawyer " .. sol_str(super_cost) }
  opts[#opts + 1] = { k = "bob",    label = "Cheap lawyer " .. sol_str(bob_cost) }
  opts[#opts + 1] = { k = "public", label = "Public defender" }
  opts[#opts + 1] = { k = "run",    label = "Ditch cart & run" }

  local cursor, chosen = 1, nil
  local prev = onion.buttons()
  while not chosen do
    local lines = { "JB PRITZKER LAW!", "Caught buying on .onion" }
    for i, o in ipairs(opts) do
      lines[#lines + 1] = ((i == cursor) and "> " or "  ") .. o.label
    end
    screen(lines, { font = "bold" })
    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #opts end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #opts then cursor = 1 end
    elseif btn == "cancel" then chosen = "run"
    elseif btn == "select" then chosen = opts[cursor].k
    end
  end

  local function drop_onions() for i = 1, #DRUGS do S.inv[i] = 0 end end

  if chosen == "retainer" then
    S.gun = S.gun - 1
    notify({ "Your retained lawyer", "got it dropped. Kept", "your onions, no jail." })
  elseif chosen == "super" then
    local pay = math.min(super_cost, S.sol); S.sol = S.sol - pay
    notify({ "Top lawyer wins!", "Charges dropped.", "Paid " .. sol_str(pay) .. ", 0 days." })
  elseif chosen == "bob" then
    local pay = math.min(bob_cost, S.sol); S.sol = S.sol - pay
    jail(2)
    notify({ "Cheap lawyer settles.", "Paid " .. sol_str(pay) .. ".", "2 days in County jail." })
  elseif chosen == "public" then
    if chance(PD_GAMEOVER) then
      S.hp = 0 -- held indefinitely -> game over
      notify({ "Public defender folds.", "You're held", "indefinitely. Over." })
    else
      local d = rnd(2, 4); jail(d)
      notify({ "Public defender stalls.", d .. " days in County jail.", "Kept your onions." })
    end
  else -- run
    if chance(RUN_ESCAPE) then
      notify({ "You ditched the cart", "and ran! Got away", "with your onions." })
    else
      drop_onions()
      jail(2)
      notify({ "Caught running!", "Onions seized,", "2 days in jail." })
    end
  end
end

-- A shakedown for SHAKEDOWN_PCT of your SOL wallet. Deducts and returns the
-- milli-SOL lost.
local function shakedown_20()
  local loss = math.floor(S.sol * (SHAKEDOWN_PCT / 100))
  S.sol = S.sol - loss
  return loss
end

local function travel_events()
  -- Grace window: the first GRACE_DAYS are free of raids and shakedowns so you
  -- can build a stake before the city comes after you. Good events still happen.
  local penalties_on = S.day > GRACE_DAYS

  -- Pritzker-raid chance scales with how many pounds of contraband you carry.
  -- A raid is the ONE bad event for this trip -- it returns afterward so you are
  -- never raided AND skimmed on the same travel.
  if penalties_on and carried() > 0 then
    local risk = RAID_BASE + math.floor(carried() / RAID_PER_UNIT)
    if risk > RAID_CAP then risk = RAID_CAP end
    if chance(risk) then
      raid_encounter()
      return
    end
  end

  -- Free produce find.
  if chance(12) and space_left() > 5 then
    local i = rnd(1, #DRUGS)
    local amt = rnd(5, math.min(40, space_left()))
    S.inv[i] = S.inv[i] + amt
    local finds = {
      "Produce truck spilled!",
      "Raided a dumpster!",
      "Abandoned farm stand!",
    }
    notify({ finds[rnd(1, #finds)], "Grabbed " .. amt .. " lb " .. DRUGS[i].name })
    return
  end

  -- Big buyer: a wholesaler wants an onion you're already holding, at a premium.
  -- Rewards holding/speculation and turns a full cart into a payday.
  if chance(9) then
    local held = {}
    for i = 1, #DRUGS do if S.inv[i] > 0 then held[#held + 1] = i end end
    if #held > 0 then
      local i = held[rnd(1, #held)]
      local mult = CITY_MULT[S.city] or 1.0
      local price = math.max(DRUGS[i].high, math.floor(DRUGS[i].high * (1.6 + math.random()) * mult))
      local qty = S.inv[i]
      local total = price * qty           -- USD cents
      local pay = usd_to_msol(total)      -- credited in SOL
      local prev = onion.buttons()
      screen({
        "BIG BUYER!",
        "Wants all your " .. DRUGS[i].name,
        qty .. " lb @ " .. usd(price),
        "Total " .. usd(total) .. " = " .. sol_str(pay),
        "SELECT sell  CANCEL keep",
      }, { font = "bold" })
      local btn
      repeat btn = wait_button(prev) until btn == "select" or btn == "cancel"
      if btn == "select" then
        S.sol = S.sol + pay
        S.inv[i] = 0
        notify({ "Sold the lot!", "+" .. sol_str(pay), "Wallet " .. sol_str(S.sol) })
      end
      return
    end
  end

  -- Small windfall: a little SOL luck to keep momentum up.
  if chance(8) then
    local gain = rnd(50, 400)  -- milli-SOL
    S.sol = S.sol + gain
    local wins = {
      { "Found a dropped Ledger!", "+" .. sol_str(gain) },
      { "Vendor tips you in SOL", "for a hot lead. +" .. sol_str(gain) },
      { "Airdrop hits your wallet!", "+" .. sol_str(gain) },
      { "Won a bar bet.", "+" .. sol_str(gain) },
    }
    notify(wins[rnd(1, #wins)])
    return
  end

  -- Hot tip: a rumor that a good will be hot in some neighborhood. Sets a tip
  -- that generate_market() cashes in when you arrive there -- real, actionable
  -- intel, so the player has a plan instead of just reacting.
  if not S.tip and chance(11) then
    local i = rnd(1, #DRUGS)
    local c = rnd(1, #CITIES)
    S.tip = { good = i, city = c }
    notify({
      "Word on the street:",
      DRUGS[i].name .. " is about to",
      "pop in " .. CITIES[c] .. ".",
      "Get there to cash in.",
    })
    return
  end

  -- FBI confiscation: feds seize a chunk of the onions you're carrying.
  if penalties_on and carried() > 0 and chance(FBI_CHANCE) then
    local pct = rnd(FBI_MIN, FBI_MAX)
    local seized = 0
    for i = 1, #DRUGS do
      local take = math.floor(S.inv[i] * (pct / 100))
      S.inv[i] = S.inv[i] - take
      seized = seized + take
    end
    if seized > 0 then
      notify({
        "FBI raids your stash!",
        "Feds confiscate your onions.",
        "Seized " .. seized .. " lb",
        "(" .. pct .. "%)",
      })
      return
    end
  end

  -- Policy / law event: Springfield & City Hall skim a % of your SOL wallet.
  if penalties_on and S.sol > 200 and chance(POLICY_CHANCE) then
    local pct = rnd(POLICY_MIN, POLICY_MAX)
    local loss = math.floor(S.sol * (pct / 100))
    S.sol = S.sol - loss
    local hit = "-" .. sol_str(loss) .. " (" .. pct .. "%)"
    local laws = {
      { "Mayor hikes the Chicago", "Digital Asset Tax.", "Hit: " .. hit },
      { "Cook County contraband", "fee assessed.", "Hit: " .. hit },
      { "IL Dept of Revenue", "audits your wallet:", hit },
      { "Mugged on the L!", "Lost: " .. hit },
    }
    notify(laws[rnd(1, #laws)])
    return
  end

  -- Jiaming films your onion buy on her iPhone -- pay to delete the footage.
  if penalties_on and S.sol > 100 and chance(SHAKE_CHANCE) then
    local loss = shakedown_20()
    notify({
      "Jiaming filmed your",
      "onion buy on iPhone!",
      "Pay to delete it.",
      "Lost " .. SHAKEDOWN_PCT .. "%:",
      "-" .. sol_str(loss),
    })
    return
  end

  -- Police chase -- you escape in a Tippi5star Uber, for a price.
  if penalties_on and S.sol > 100 and chance(SHAKE_CHANCE) then
    local loss = shakedown_20()
    notify({
      "Cops on you! You jumped",
      "in a Tippi5star Uber.",
      "Payoff " .. SHAKEDOWN_PCT .. "%:",
      "-" .. sol_str(loss),
    })
    return
  end

  -- Lobbyist offering a lawyer on retainer (your defense in a Pritzker raid).
  if chance(10) then
    local price = rnd(8000, 25000)   -- USD cents ($80-$250)
    local pay = usd_to_msol(price)
    if S.sol >= pay then
      local prev = onion.buttons()
      screen({
        "Lobbyist: a lawyer",
        "vs Pritzker raids.",
        "Price " .. usd(price) .. " = " .. sol_str(pay),
        "",
        "SELECT buy  CANCEL pass",
      }, { font = "bold" })
      local btn
      repeat btn = wait_button(prev) until btn == "select" or btn == "cancel"
      if btn == "select" then
        S.sol = S.sol - pay
        S.gun = S.gun + 1
        notify({ "Lawyer retained.", "Lawyers: " .. S.gun })
      end
    end
  end

  -- Bigger produce cart (cheap random capacity upgrade, +40 lb).
  if chance(10) then
    local price = rnd(3000, 12000)   -- USD cents ($30-$120)
    local pay = usd_to_msol(price)
    if S.sol >= pay then
      local prev = onion.buttons()
      screen({
        "Supplier: bigger cart",
        "+40 lb capacity.",
        "Price " .. usd(price) .. " = " .. sol_str(pay),
        "",
        "SELECT buy  CANCEL skip",
      }, { font = "bold" })
      local btn
      repeat btn = wait_button(prev) until btn == "select" or btn == "cancel"
      if btn == "select" then
        S.sol = S.sol - pay
        S.coat = S.coat + 40
        notify({ "Bigger cart!", "Capacity: " .. S.coat .. " lb" })
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Quantity picker (shared by buy / sell / Coinbase). All values are USD.
-------------------------------------------------------------------------------

-- title, unit price (USD cents), max units, opts {step, bigstep, start}. Returns
-- the chosen qty (0 = cancel). Pass unit_price = 1 for a plain USD amount picker
-- (qty is then whole dollars); the screen shows Amount instead of Unit/Qty/Cost.
local function pick_quantity(title, unit_price, max_units, opts)
  opts = opts or {}
  local step = opts.step or 1
  local big  = opts.bigstep or 10
  if max_units <= 0 then
    notify({ title, "Nothing to do here." })
    return 0
  end
  local qty = math.min(opts.start or 0, max_units)
  local prev = onion.buttons()
  while true do
    local lines = { title }
    if unit_price ~= 1 then
      lines[#lines + 1] = "Unit " .. usd(unit_price) .. "/lb"
      lines[#lines + 1] = "Qty " .. qty .. " lb (max " .. max_units .. ")"
      lines[#lines + 1] = "Cost " .. usd(qty * unit_price)
    else
      lines[#lines + 1] = "Amount $" .. commas(qty)
      lines[#lines + 1] = "(max $" .. commas(max_units) .. ")"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "UP/DN +-" .. step .. "  LR +-" .. big
    lines[#lines + 1] = "SELECT ok   CANCEL back"
    screen(lines, { font = "small" })
    local btn = wait_button(prev)
    if btn == "up" then qty = math.min(max_units, qty + step)
    elseif btn == "down" then qty = math.max(0, qty - step)
    elseif btn == "right" then qty = math.min(max_units, qty + big)
    elseif btn == "left" then qty = math.max(0, qty - big)
    elseif btn == "select" then return qty
    elseif btn == "cancel" then return 0
    end
  end
end

-------------------------------------------------------------------------------
-- Buy / Sell screens
-------------------------------------------------------------------------------

local function list_screen(title, rows, cursor, footer)
  local lines = { title }
  for i, r in ipairs(rows) do
    local marker = (i == cursor) and ">" or " "
    lines[#lines + 1] = marker .. " " .. r
  end
  lines[#lines + 1] = footer
  screen(lines, { font = "small" })
end

local function do_buy()
  local cursor = 1
  local prev = onion.buttons()
  while true do
    -- Cart full: nothing is buyable, so don't show a list of things you can't take.
    if space_left() <= 0 then
      notify({ "Your cart is full.", "Sell some, or grab a", "bigger cart." })
      return
    end
    -- Only list onions on sale that you can afford at least one pound of.
    local wallet_usd = msol_to_usd(S.sol)
    local rows = {}
    local available = {}
    local on_sale = 0
    for i, d in ipairs(DRUGS) do
      local p = S.market[i] or 0
      if p > 0 then
        on_sale = on_sale + 1
        if p <= wallet_usd then
          available[#available + 1] = i
          rows[#rows + 1] = d.name .. " " .. usd(p)
        end
      end
    end
    if on_sale == 0 then
      notify({ "Nothing for sale today.", "Try another area." })
      return
    end
    if #available == 0 then
      notify({ "Can't afford anything", "on sale here today.", "Sell, or find cheaper." })
      return
    end
    if cursor > #available then cursor = #available end

    list_screen("BUY  free " .. space_left() .. " lb",
      rows, cursor, "SELECT buy  CANCEL back")
    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #available end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #available then cursor = 1 end
    elseif btn == "cancel" then return
    elseif btn == "select" then
      local i = available[cursor]
      local price = S.market[i]                              -- USD cents/lb
      local max_afford = math.floor(wallet_usd / price)      -- pounds
      local max_units = math.min(max_afford, space_left())
      local qty = pick_quantity("Buy " .. DRUGS[i].name, price, max_units)
      if qty > 0 then
        local cost = usd_to_msol(qty * price)
        if cost > S.sol then cost = S.sol end
        S.sol = S.sol - cost
        S.inv[i] = S.inv[i] + qty
        notify({ "Bought " .. qty .. " lb " .. DRUGS[i].name,
          "for " .. sol_str(cost), "(" .. usd(qty * price) .. ")" })
      end
    end
  end
end

local function do_sell()
  local cursor = 1
  local prev = onion.buttons()
  while true do
    local rows = {}
    local holdings = {}
    for i, d in ipairs(DRUGS) do
      if S.inv[i] > 0 then
        holdings[#holdings + 1] = i
        local p = S.market[i] or 0
        local pl = p > 0 and usd(p) or "--"
        rows[#rows + 1] = d.name .. " " .. pl
      end
    end
    if #holdings == 0 then
      notify({ "Your cart is empty.", "Go buy something first." })
      return
    end
    if cursor > #holdings then cursor = #holdings end

    list_screen("SELL", rows, cursor, "SELECT sell CANCEL back")
    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #holdings end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #holdings then cursor = 1 end
    elseif btn == "cancel" then return
    elseif btn == "select" then
      local i = holdings[cursor]
      local price = S.market[i] or 0
      if price <= 0 then
        notify({ "Nobody's buying " .. DRUGS[i].name, "here today." })
      else
        local qty = pick_quantity("Sell " .. DRUGS[i].name, price, S.inv[i])
        if qty > 0 then
          local gain = usd_to_msol(qty * price)
          S.sol = S.sol + gain
          S.inv[i] = S.inv[i] - qty
          notify({ "Sold " .. qty .. " lb " .. DRUGS[i].name,
            "for " .. sol_str(gain), "(" .. usd(qty * price) .. ")" })
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Lincoln Park store -- reliable (but pricey) cart-capacity upgrades, in SOL
-------------------------------------------------------------------------------

local function do_store()
  local prev = onion.buttons()
  while true do
    local price = CART_BASE_COST + S.cart_lvl * CART_COST_STEP  -- USD cents
    local pay = usd_to_msol(price)
    screen({
      "LINCOLN PARK STORE",
      "Cart +" .. CART_UPGRADE .. " lb",
      "Capacity now " .. S.coat .. " lb",
      "Price " .. usd(price) .. " = " .. sol_str(pay),
      "",
      "SELECT buy  CANCEL back",
    }, { font = "small" })
    local btn = wait_button(prev)
    if btn == "cancel" then return
    elseif btn == "select" then
      if S.sol < pay then
        notify({ "Not enough SOL.", "Need " .. sol_str(pay) .. ".",
          "You have " .. sol_str(S.sol) .. "." })
      else
        S.sol = S.sol - pay
        S.coat = S.coat + CART_UPGRADE
        S.cart_lvl = S.cart_lvl + 1
        notify({ "Bigger cart!", "Capacity " .. S.coat .. " lb.",
          "Next +" .. CART_UPGRADE .. " lb costs more." })
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Coinbase -- Brian Armstrong's margin desk (The Loop / OnionDAO HQ only).
-- Borrow against your wallet or pay the loan down. The loan is in USD; you pay
-- and draw in SOL at the day's price.
-------------------------------------------------------------------------------

local function do_coinbase()
  local cursor = 1
  local actions = { "Pay loan", "Borrow", "SOL price" }
  local prev = onion.buttons()
  while true do
    local lines = {
      "COINBASE - OnionDAO HQ",
      "Broker: Brian Armstrong",
      "Owe " .. usd(S.debt),
    }
    for i, a in ipairs(actions) do
      lines[#lines + 1] = ((i == cursor) and "> " or "  ") .. a
    end
    lines[#lines + 1] = "[CANCEL] back"
    screen(lines, { font = "small" })

    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #actions end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #actions then cursor = 1 end
    elseif btn == "cancel" then return
    elseif btn == "select" then
      local a = actions[cursor]
      if a == "Pay loan" then
        -- Pay in whole dollars, capped by what you owe and what your SOL covers.
        local wallet_usd = msol_to_usd(S.sol)
        local max_pay = math.floor(math.min(S.debt, wallet_usd) / 100)  -- whole $
        local dollars = pick_quantity("Pay loan", 1, max_pay,
          { step = 10, bigstep = 100, start = max_pay })
        if dollars > 0 then
          local cents = dollars * 100
          local pay = usd_to_msol(cents)
          if pay > S.sol then pay = S.sol end
          S.sol = S.sol - pay
          S.debt = S.debt - cents
          notify({ "Paid " .. usd(cents) .. " on loan", "(" .. sol_str(pay) .. ")",
            "Owe " .. usd(S.debt) })
        end
      elseif a == "Borrow" then
        local dollars = pick_quantity("Borrow (max $5000)", 1, 5000,
          { step = 10, bigstep = 100 })
        if dollars > 0 then
          local cents = dollars * 100
          local draw = usd_to_msol(cents)
          S.sol = S.sol + draw
          S.debt = S.debt + cents
          notify({ "Borrowed " .. usd(cents), "(+" .. sol_str(draw) .. ")",
            "Owe " .. usd(S.debt) })
        end
      elseif a == "SOL price" then
        notify({
          "SOLANA price today",
          usd(S.sol_price) .. " / SOL",
          "Day " .. S.day .. "/" .. TOTAL_DAYS .. " of 2025",
          "Your " .. sol_str(S.sol),
          "= " .. usd(msol_to_usd(S.sol)),
        }, { no_header = true })
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Travel (advances the day)
-------------------------------------------------------------------------------

local function accrue_interest()
  S.debt = math.floor(S.debt * (1 + DEBT_RATE))
  set_sol_for_day()
end

local function do_travel()
  local cursor = 1
  local prev = onion.buttons()
  while true do
    local rows = {}
    for i, c in ipairs(CITIES) do
      rows[#rows + 1] = c .. (i == S.city and "  (here)" or "")
    end
    list_screen("TRAVEL  Day " .. S.day .. "/" .. TOTAL_DAYS,
      rows, cursor, "SELECT go  CANCEL stay")
    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #CITIES end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #CITIES then cursor = 1 end
    elseif btn == "cancel" then return false
    elseif btn == "select" then
      if cursor == S.city then
        notify({ "You're already there.", "Pick somewhere else." })
      else
        S.city = cursor
        S.day = S.day + 1
        accrue_interest()
        travel_events()
        if S.hp <= 0 then return true end
        local ev = generate_market()
        if #ev > 0 then notify(ev) end
        save_game()
        if S.day > TOTAL_DAYS then return true end
        return false
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Main menu / status screen
-------------------------------------------------------------------------------

local onboarding  -- forward declaration; defined in the Entry section below

local function main_menu()
  local cursor = 1
  local prev = onion.buttons()
  while not S.over do
    -- Track the best net worth reached this run, for the end-of-year summary.
    local nw_now = net_worth()
    if nw_now > (S.peak or 0) then S.peak = nw_now end
    local in_loop = CITIES[S.city] == BANK_CITY
    local in_store = CITIES[S.city] == CART_CITY
    local actions = { "Buy", "Sell", "Travel" }
    if in_loop then actions[#actions + 1] = "Coinbase" end
    if in_store then actions[#actions + 1] = "Store" end
    actions[#actions + 1] = "Stash"
    actions[#actions + 1] = "Help"  -- guidance; CANCEL quits (and saves)
    if cursor > #actions then cursor = #actions end

    -- Wallet (SOL + USD) is in the header. City + 1 status line + up to 6 actions.
    local lines = {
      CITIES[S.city],
      "Day " .. S.day .. "/" .. TOTAL_DAYS .. "  Owe " .. usd0(S.debt),
    }
    for i, a in ipairs(actions) do
      lines[#lines + 1] = ((i == cursor) and "> " or "  ") .. a
    end
    screen(lines, { font = "small" })

    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #actions end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #actions then cursor = 1 end
    elseif btn == "cancel" then
      save_game(); return "quit"
    elseif btn == "select" then
      local a = actions[cursor]
      if a == "Buy" then do_buy()
      elseif a == "Sell" then do_sell()
      elseif a == "Coinbase" then do_coinbase()
      elseif a == "Store" then do_store()
      elseif a == "Stash" then
        local nw = net_worth()
        local pct = math.floor(nw / GOAL_NET * 100)
        if pct < 0 then pct = 0 end
        local rows = {
          "NET WORTH " .. usd(nw),
          "= " .. sol_str(usd_to_msol(nw)) .. " (" .. pct .. "% to goal)",
          rank_title(nw),
          "",
        }
        local n0 = #rows
        for i, d in ipairs(DRUGS) do
          if S.inv[i] > 0 then rows[#rows + 1] = d.name .. " x" .. S.inv[i] .. " lb" end
        end
        if #rows == n0 then rows[#rows + 1] = "(cart is empty)" end
        notify(rows, { no_header = true })
      elseif a == "Travel" then
        local ended = do_travel()
        if ended then return "ended" end
        save_game()
      elseif a == "Help" then
        onboarding()
      end
    end
    save_game()
  end
  return "ended"
end

-------------------------------------------------------------------------------
-- Game over / scoring
-------------------------------------------------------------------------------

local function game_over()
  S.over = true
  local final = net_worth()  -- USD cents
  local why
  if S.hp <= 0 then why = "Held indefinitely."
  else why = "Out of time. Game over." end

  -- Persist a personal best so repeat plays have a target.
  local best = tonumber(onion.kv_get and onion.kv_get("ow_best") or "") or nil
  local is_best = (not best) or (final > best)
  if is_best and onion.kv_set then onion.kv_set("ow_best", tostring(final)) end

  clear_save() -- next launch starts a new run

  if final > (S.peak or 0) then S.peak = final end
  local lines = {
    "END OF 2025",
    why,
    "Net worth: " .. usd(final),
    "= " .. sol_str(usd_to_msol(final)),
    "Rank: " .. rank_title(final),
    "Peak: " .. usd(S.peak),
  }
  if final >= GOAL_NET then lines[#lines + 1] = "ONION KINGPIN -- you win!" end
  if is_best then lines[#lines + 1] = "NEW BEST!"
  elseif best then lines[#lines + 1] = "Best: " .. usd(best) end

  notify(lines, { no_header = true })
end

-------------------------------------------------------------------------------
-- ONLINE / staked-match hooks (Phase 2 — see ONIONWARS.md)
-------------------------------------------------------------------------------
-- All of this is gated behind STAKING_ENABLED (false) and an ow_apikey in NVS,
-- so in free play the game makes no network calls at all. These hooks report
-- score / move real onions (the token) server-side; they are unrelated to the
-- in-game SOL/USD ledger above.

-- Returns the configured match code, or nil for plain single-player.
function active_match()
  if not STAKING_ENABLED then return nil end
  if not onion.kv_get then return nil end
  local code = onion.kv_get("ow_match")
  if code and code ~= "" then return code end
  return nil
end

-- Pull a JSON string field with a plain Lua pattern (no JSON lib on-device).
local function json_field(body, key)
  if type(body) ~= "string" then return nil end
  return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

-- The OnionDAO external API key, provisioned out-of-band into NVS (never
-- hardcoded). Without it, no real-onion action can run.
local function external_key()
  local k = onion.kv_get and onion.kv_get("ow_apikey")
  if k and k ~= "" then return k end
  return nil
end

-- Move `amount` onions from the current player to `recipient` (a handle) using
-- the real Onion Requests API (API.md -> "Onion Requests"): create a transfer
-- request, then poll until it settles. Returns true only on "completed".
local function onion_transfer(recipient, amount, note, ext_id)
  if not (onion.http_post and onion.http_get and onion.username) then return false end
  local key = external_key()
  if not key then return false end
  local headers = { Authorization = "Bearer " .. key }
  local body = string.format(
    '{"type":"transfer","username":"%s","recipientUsername":"%s","amount":%d,'
    .. '"requester":"onionwars","externalId":"%s","note":"%s"}',
    onion.username(), recipient, math.floor(amount), ext_id, note)
  local ok, resp = pcall(function()
    return onion.http_post(API_BASE .. "/api/public/onions/requests", body,
      { content_type = "application/json", headers = headers, timeout_ms = 15000 })
  end)
  if not ok or type(resp) ~= "table" or not resp.status
     or resp.status < 200 or resp.status >= 300 then
    return false
  end
  local id = json_field(resp.body, "id")
  if not id then return false end
  local deadline = (onion.millis and onion.millis() or 0) + 90000
  while true do
    onion.sleep(2000)
    local gok, gresp = pcall(function()
      return onion.http_get(API_BASE .. "/api/public/onions/requests/" .. id,
        { headers = headers, timeout_ms = 10000 })
    end)
    if gok and type(gresp) == "table" then
      local st = json_field(gresp.body, "status")
      if st == "completed" then return true end
      if st == "denied" or st == "failed" then return false end
    end
    if onion.millis and onion.millis() > deadline then return false end
  end
end

-- Staked-match buy-in to the pot, settled by a real, user-approved transfer.
function request_loan(real_onions)
  local match = active_match()
  if not match then return false end
  local ext = "loan_" .. match .. "_"
    .. (onion.onion_id and onion.onion_id() or 0) .. "_"
    .. (onion.millis and onion.millis() or 0)
  return onion_transfer(POT_HANDLE, real_onions, "OnionWars loan", ext)
end

-------------------------------------------------------------------------------
-- Entry
-------------------------------------------------------------------------------

local function intro_if_new(is_resume)
  if is_resume then
    notify({ "ONIONWARS 2025", "Resuming run...",
      "Day " .. S.day .. " - " .. CITIES[S.city] })
  elseif active_match() then
    notify({
      "ONIONWARS 2025",
      "Chicago. Staked match.",
      "Entry " .. commas(ENTRY_FEE) .. " paid.",
      "Win: top net worth gets",
      WINNER_PCT .. "% of the pot.",
      TAX_PCT .. "% tax to " .. TAX_HANDLE,
    })
  else
    notify({
      "ONIONWARS - 2025",
      "Trade onions in SOL.",
      "Goal: " .. usd0(GOAL_NET) .. " net",
      "worth = Onion Kingpin.",
      "Pay Coinbase fast:",
      "loan grows 8%/day!",
    })
  end
end

-- Onboarding / Help: a few simple, skippable cards. Paged with SELECT; CANCEL
-- skips the rest. Shown automatically on first run (gated by the ow_intro NVS
-- flag in run()) and any time from the "Help" menu item.
function onboarding()
  local cards = {
    {
      "ONIONWARS 2025",
      "",
      "Onion trader in",
      "Chicago. Buy low,",
      "sell high, 30 days.",
      "Biggest net worth wins.",
    },
    {
      "PRICED IN SOL",
      "",
      "Onions cost USD;",
      "you pay in Solana.",
      "SOL's price swings all",
      "year - timing matters!",
    },
    {
      "CONTROLS",
      "",
      "UP/DN: move, +-1",
      "L/R: +-10",
      "SELECT: confirm",
      "CANCEL: back / quit",
    },
    {
      "HOW TO PLAY",
      "",
      "TRAVEL to a hood,",
      "BUY cheap onions,",
      "SELL where pricey.",
      "Watch the prices.",
    },
    {
      "COINBASE",
      "",
      "Broker Brian Armstrong",
      "lends at OnionDAO HQ",
      "(The Loop). Loan grows",
      "8%/day - pay it FAST!",
    },
    {
      "WATCH OUT",
      "",
      "Carry a lot = raid,",
      "FBI seizure, shakedown",
      "risk. Carry less to",
      "stay safer on the road.",
    },
    {
      "SIDE PLAYS",
      "",
      "Lincoln Park STORE:",
      "buy cart space (pricey).",
      "Hold SOL or onions to",
      "ride the price swings.",
    },
    {
      "GET RICH",
      "",
      "Goal $25,000 net =",
      "Onion Kingpin.",
      "",
      "SELECT to play!",
    },
  }
  local i = 1
  local prev = onion.buttons()
  while i <= #cards do
    local rows = {}
    for _, l in ipairs(cards[i]) do rows[#rows + 1] = l end
    rows[#rows + 1] = (i < #cards)
      and ("SEL next CAN skip " .. i .. "/" .. #cards)
      or "SELECT to play!"
    screen(rows, { font = "small", no_header = true })
    local btn = wait_button(prev)
    if btn == "cancel" then return
    elseif btn == "select" or btn == "right" or btn == "down" then i = i + 1
    elseif (btn == "left" or btn == "up") and i > 1 then i = i - 1
    end
  end
end

-- Title splash shown at launch: big "ONION WARS" logo, then waits for a press.
local function splash()
  if onion.display_begin then onion.display_begin() end
  onion.display_lines({ "ONION", "WARS" }, 64, 48, 42, { clear = true, font = "large" })
  onion.display_lines({ "Chicago 2025", "Press SELECT to play" }, 8, 120, 20,
    { clear = false, font = "small" })
  if onion.display_commit then onion.display_commit() end
  local prev = onion.buttons()
  local start = onion.millis and onion.millis() or nil
  while true do
    local b = onion.buttons()
    if (b.select and not prev.select) or (b.cancel and not prev.cancel)
       or (b.up and not prev.up) or (b.down and not prev.down)
       or (b.left and not prev.left) or (b.right and not prev.right) then
      return
    end
    prev = b
    if start and (onion.millis() - start) > 8000 then return end
    onion.sleep(60)
  end
end

local function run()
  splash()
  seed_rng()
  local loaded = load_game()
  local is_resume = false
  if loaded and not loaded.over and loaded.day <= TOTAL_DAYS then
    S = loaded
    is_resume = true
  else
    S = fresh_state()
  end

  -- First-timers get the onboarding tutorial (once); everyone else gets the
  -- short resume/staked/free-play card.
  local seen = onion.kv_get and onion.kv_get("ow_intro")
  if not is_resume and not active_match() and not seen then
    onboarding()
    if onion.kv_set then onion.kv_set("ow_intro", "1") end
  else
    intro_if_new(is_resume)
  end
  if not is_resume or #S.market == 0 then
    local ev = generate_market()
    if #ev > 0 then notify(ev) end
  end

  local result = main_menu()
  if result == "ended" then
    game_over()
  end

  onion.release_display()
end

run()
