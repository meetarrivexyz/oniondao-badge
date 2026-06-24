-- OnionWars (Chicago) -- formerly "Drugwars: Onion Edition"
-- A badge-native, onion-themed take on the classic trading game, in onions
-- instead of dollars. Buy low, sell high across Chicago over 2 days, dodge the
-- Pritzker law, pay the Dealer loan, and build the biggest stash.
--
-- The currency is the OnionDAO "onion" (your badge's Onion token). The in-game
-- balances (the 2,000 cash / 5,500 debt you start a run with) are an in-game
-- ledger saved to NVS, NOT real on-chain transfers.
--
-- STAKED MATCH: entering a match costs 100 REAL onions. Every entry goes to the
-- Dealer escrow wallet; at settlement the pot is split 80% to the highest net
-- worth in OnionDAO and 20% as the City of Chicago Digital Asset Tax, paid to
-- the OnionDAO handle @chicagotax. That real token movement is settled
-- SERVER-SIDE (stake-in and payout are server-built Solana transfers the badge
-- signs) -- see software/mods/onion-os/ONIONWARS.md. The ONLINE hooks at the
-- bottom of this file report the score; they never move tokens directly.
--
-- Controls:
--   UP / DOWN     move the cursor / change quantity by 1
--   LEFT / RIGHT  change quantity by 10 (and page where noted)
--   SELECT        confirm the highlighted action
--   CANCEL        back out one screen / (on main menu) save and exit

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local TOTAL_DAYS   = 30   -- one month: 30 days / 30 moves
local START_CASH   = 2000
local START_DEBT   = 5500
local START_HP     = 30
local START_COAT   = 100
local DEBT_RATE    = 0.10   -- Chicago loan-shark "juice": 10%/day, compounds daily
local BANK_RATE     = 0.05  -- savings interest per day
local GOAL_NET      = 1000000  -- the "retire" target: become the Onion Kingpin
local SCREEN_W      = 264
local SCREEN_H      = 176

-- Difficulty / fairness knobs. Higher = more punishing. Defaults are tuned so a
-- careful player can recover from a bad break instead of wanting to throw the
-- badge: at most ONE bad event per travel, a grace window at the start, gentler
-- raid odds, and smaller, rarer shakedowns.
local GRACE_DAYS    = 3    -- first N days have no raids or shakedowns
local RAID_BASE     = 6    -- base Pritzker-raid % while carrying onions
local RAID_PER_UNIT = 20   -- +1% raid risk per this many crates carried
local RAID_CAP      = 25   -- max raid %
local POLICY_CHANCE = 10   -- % chance of a policy/tax skim on a travel
local POLICY_MIN    = 6    -- a policy skim takes POLICY_MIN..POLICY_MAX % of cash
local POLICY_MAX    = 15
local SHAKE_CHANCE  = 7    -- % chance EACH of the Jiaming / Tippi shakedowns
local SHAKEDOWN_PCT = 12   -- % taken by a shakedown
local PD_GAMEOVER   = 8    -- public defender: % chance you're held for good
local RUN_ESCAPE    = 80   -- ditch-and-run: % chance of a clean getaway

-- Master switch for real-onion staking. While false, the game is pure free
-- play: no entry fee, no Onion Loan charge, no score reporting -- nothing ever
-- touches the wallet, regardless of any ow_match key. Flip to true once the
-- server-side match/loan routes are live (see ONIONWARS.md).
local STAKING_ENABLED = false

-- Staked-match economics (real onions; settled server-side, see ONIONWARS.md).
-- It costs ENTRY_FEE real onions to enter a staked match. Every player's entry
-- goes into the Dealer escrow wallet. At settlement the pot is split: WINNER_PCT
-- to the highest net worth in OnionDAO, and TAX_PCT as the City of Chicago
-- Digital Asset Tax paid to the OnionDAO handle TAX_HANDLE.
local ENTRY_FEE  = 100
local WINNER_PCT = 80
local TAX_PCT    = 20
local TAX_HANDLE = "@chicagotax"

-- Global leaderboard. Every finished run posts its final net worth to a global
-- high-score board (no real onions move -- this is just bragging rights), and
-- the "Scores" menu item fetches the current top players. Works in free play
-- AND staked matches; needs a player identity (onion.onion_id) to submit, but
-- anyone can view. See ONIONWARS.md for the server contract.
local LEADERBOARD_URL   = "https://oniondao.dev/api/games/onionwars/leaderboard"
local LEADERBOARD_TOP   = 10  -- how many players to fetch/show

-- Onion Loan: spend real onions to take out a bigger in-game loan (more buying
-- power). Each real onion buys LOAN_RATE in-game onions of cash, added to your
-- in-game debt (same 20%/day loan-shark mechanics). The real onions split like the pot:
-- TAX_PCT goes to @chicagotax, the rest goes to the holding (escrow) wallet.
-- In free play (no staked match) the loan is simulated -- no real onions move.
local LOAN_RATE       = 100  -- in-game cash granted per real onion spent
local LOAN_MAX_ONIONS = 100  -- max real onions per loan

-- The contraband you trade. Onion-themed goods, cheapest -> priciest. name,
-- low price, high price (onions). (Internally still called DRUGS; the table
-- order maps to the saved inventory slots, so keep it stable across updates.)
local DRUGS = {
  { name = "Scallions",   low = 11,    high = 60    },
  { name = "Shallots",    low = 480,   high = 1280  },
  { name = "Red Onions",  low = 600,   high = 1300  },
  { name = "Vidalia",     low = 1000,  high = 4500  },
  { name = "Garlic",      low = 5500,  high = 13000 },
  { name = "Black Garlic",low = 15000, high = 29000 },
}

local CITIES = {
  "The Loop",
  "South Side",
  "West Side",
  "Wicker Park",
  "Englewood",
  "Lincoln Park",
}
local BANK_CITY = "The Loop"  -- bank + loan shark live here (Chicago downtown)

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
    cash     = START_CASH,
    debt     = START_DEBT,
    bank     = 0,
    hp       = START_HP,
    coat     = START_COAT,        -- carrying capacity
    gun      = 0,                 -- number of guns owned
    inv      = inv,               -- units held per drug index
    market   = {},                -- price per drug index for current city (0 = unavailable)
    over     = false,
    peak     = 0,                 -- best net worth seen this run (runtime only)
    tip      = nil,               -- pending hot-tip { good, city } (runtime only)
  }
end

-- units currently carried
local function carried()
  local n = 0
  for i = 1, #DRUGS do n = n + S.inv[i] end
  return n
end

local function space_left()
  return S.coat - carried()
end

-- total value of held drugs at current market prices (0 if not on sale)
local function stash_value()
  local v = 0
  for i = 1, #DRUGS do
    local p = S.market[i] or 0
    v = v + S.inv[i] * p
  end
  return v
end

local function net_worth()
  return S.cash + S.bank + stash_value() - S.debt
end

-- Rank ladder by net worth -- a title to chase and show off. Thresholds rise
-- toward GOAL_NET (Onion Kingpin).
local TITLES = {
  { -1,      "Broke" },           -- in the red (debt > assets)
  { 0,       "Onion Peddler" },
  { 25000,   "Onion Hustler" },
  { 100000,  "Onion Dealer" },
  { 300000,  "Onion Boss" },
  { 600000,  "Onion Baron" },
  { GOAL_NET, "Onion Kingpin" },
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

local SAVE_KEY = "ow_save2"  -- bumped to discard pre-30-day saves; starts fresh

local function serialize()
  -- flat, order-stable: day|city|cash|debt|bank|hp|coat|gun|over|inv0,inv1,...
  local parts = {
    S.day, S.city, S.cash, S.debt, S.bank, S.hp, S.coat, S.gun,
    S.over and 1 or 0,
  }
  local inv = {}
  for i = 1, #DRUGS do inv[i] = tostring(S.inv[i]) end
  return table.concat(parts, "|") .. "|" .. table.concat(inv, ",")
end

local function deserialize(blob)
  local fields = {}
  for f in string.gmatch(blob, "([^|]+)") do fields[#fields + 1] = f end
  if #fields < 10 then return nil end
  local st = fresh_state()
  st.day  = tonumber(fields[1]) or 1
  st.city = tonumber(fields[2]) or 1
  st.cash = tonumber(fields[3]) or START_CASH
  st.debt = tonumber(fields[4]) or START_DEBT
  st.bank = tonumber(fields[5]) or 0
  st.hp   = tonumber(fields[6]) or START_HP
  st.coat = tonumber(fields[7]) or START_COAT
  st.gun  = tonumber(fields[8]) or 0
  st.over = (tonumber(fields[9]) or 0) == 1
  local idx = 1
  for u in string.gmatch(fields[10], "([^,]+)") do
    st.inv[idx] = tonumber(u) or 0
    idx = idx + 1
  end
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

-- Onion amounts show as a plain comma-grouped number (e.g. 1,405). Every value
-- on screen is labelled (Cash, Owe, Price, Cost...) and the whole game is in
-- onions, so no currency prefix is needed -- and a leading "O" read like a zero.
local function onions(n) return commas(n) end

-- Layout constants for the 264x176 e-paper panel using FreeMono9pt fonts.
-- The 9pt mono font advances ~18px per line and ~11px per char, so lines must
-- be >=18px apart and <=22 chars wide, and at most ~9 lines fit top to bottom.
local LH       = 18    -- line height (font is FreeMono9pt, ~18px tall)
local TOP_Y    = 16    -- baseline of the first line
local MAX_CHARS = 22   -- safe characters per line at x=6

-- Draw a full screen in one batched e-paper refresh. Unless opts.no_header is
-- set, a persistent "Cash N" wallet line is drawn at the very top of every
-- screen so the player always sees their spendable onions.
local function screen(lines, opts)
  opts = opts or {}
  local x  = opts.x or 6
  local y  = opts.y or TOP_Y
  local lh = opts.lh or LH
  local font = opts.font or "small"
  local out = lines
  if S and S.cash and not opts.no_header then
    out = { "Cash " .. commas(S.cash) }
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
-- opts.no_header to drop the persistent "Cash N" line (used by money-summary
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

-- Build the current city's market: each drug has a chance to be on sale at a
-- random price in its range. Returns event text lines (price shocks) if any.
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
  -- here today. This makes a tip actionable -- travel here to cash in (or buy
  -- elsewhere and sell it here). Consumes the tip.
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
-- Random travel events
-------------------------------------------------------------------------------

-- Spend `days` locked up: time passes (debt keeps compounding at the loan-shark
-- rate) while you can't trade. If this runs past the deadline, do_travel ends
-- the game on its day check.
local function jail(days)
  for _ = 1, days do
    S.day = S.day + 1
    S.debt = math.floor(S.debt * (1 + DEBT_RATE))
    S.bank = math.floor(S.bank * (1 + BANK_RATE))
  end
end

-- A JB Pritzker Law raid (the Governor's digital-asset crackdown). You're caught
-- mid onion buy and choose a defense -- a tradeoff of MONEY vs DAYS:
--   Super lawyer (dev): high $, 0 days, keep onions, always wins.
--   Bob (mid lawyer):   mid $, 2 days in jail, keep onions.
--   Public defender:    free, 4-6 days in jail, keep onions; small chance you
--                       are held indefinitely (game over).
--   Ditch cart & run:   free + 0 days, but you drop ALL your onions (keep cash);
--                       sometimes you're caught anyway.
-- A lawyer on retainer (S.gun, bought from a lobbyist) is a free instant win.
local function raid_encounter()
  local super_cost = math.max(500, math.floor(S.cash * 0.40))
  local bob_cost   = math.max(200, math.floor(S.cash * 0.20))
  local opts = {}
  if S.gun > 0 then opts[#opts + 1] = { k = "retainer", label = "Use retainer (free)" } end
  opts[#opts + 1] = { k = "super",  label = "Hire lawyer " .. onions(super_cost) }
  opts[#opts + 1] = { k = "bob",    label = "Hire lawyer " .. onions(bob_cost) }
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
    local pay = math.min(super_cost, S.cash); S.cash = S.cash - pay
    notify({ "Top lawyer wins!", "Charges dropped.", "Paid " .. onions(pay) .. ", 0 days." })
  elseif chosen == "bob" then
    local pay = math.min(bob_cost, S.cash); S.cash = S.cash - pay
    jail(2)
    notify({ "Cheap lawyer settles.", "Paid " .. onions(pay) .. ".", "2 days in County jail." })
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

-- A shakedown for SHAKEDOWN_PCT of your money. A coin flip decides whether they
-- take that % of your cash on hand or that % of all your onions (cash + bank).
-- Deducts and returns the amount lost plus a label ("cash" or "onions").
local function shakedown_20()
  local frac = SHAKEDOWN_PCT / 100
  if rnd(1, 2) == 1 then
    local loss = math.floor(S.cash * frac)
    S.cash = S.cash - loss
    return loss, "cash"
  else
    local total = S.cash + S.bank
    local loss = math.floor(total * frac)
    local from_cash = math.min(loss, S.cash)
    S.cash = S.cash - from_cash
    S.bank = S.bank - (loss - from_cash)
    return loss, "onions"
  end
end

local function travel_events()
  -- Grace window: the first GRACE_DAYS are free of raids and shakedowns so you
  -- can build a stake before the city comes after you. Good events still happen.
  local penalties_on = S.day > GRACE_DAYS

  -- Pritzker-raid chance scales with how much contraband you are carrying.
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
    local amt = rnd(2, math.min(8, space_left()))
    S.inv[i] = S.inv[i] + amt
    local finds = {
      "Produce truck spilled!",
      "Raided a dumpster!",
      "Abandoned farm stand!",
    }
    notify({ finds[rnd(1, #finds)], "Grabbed " .. amt .. " " .. DRUGS[i].name })
    return
  end

  -- Big buyer: a wholesaler wants a good you're already holding, at a premium.
  -- Rewards holding/speculation and turns a full cart into a payday.
  if chance(9) then
    local held = {}
    for i = 1, #DRUGS do if S.inv[i] > 0 then held[#held + 1] = i end end
    if #held > 0 then
      local i = held[rnd(1, #held)]
      local mult = CITY_MULT[S.city] or 1.0
      local price = math.max(DRUGS[i].high, math.floor(DRUGS[i].high * (1.6 + math.random()) * mult))
      local qty = S.inv[i]
      local total = price * qty
      local prev = onion.buttons()
      screen({
        "BIG BUYER!",
        "Wants all your " .. DRUGS[i].name,
        qty .. " @ " .. onions(price),
        "Total " .. onions(total),
        "SELECT sell  CANCEL keep",
      }, { font = "bold" })
      local btn
      repeat btn = wait_button(prev) until btn == "select" or btn == "cancel"
      if btn == "select" then
        S.cash = S.cash + total
        S.inv[i] = 0
        notify({ "Sold the lot!", "+" .. onions(total), "Cash " .. onions(S.cash) })
      end
      return
    end
  end

  -- Small windfall: a little cash luck to keep momentum up.
  if chance(8) then
    local gain = rnd(80, 400)
    S.cash = S.cash + gain
    local wins = {
      { "Found a roll of cash!", "+" .. onions(gain) },
      { "Vendor tips you for", "a hot lead. +" .. onions(gain) },
      { "Tax refund hits!", "+" .. onions(gain) },
      { "Won a bar bet.", "+" .. onions(gain) },
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

  -- Policy / law event: Springfield & City Hall skim a % of your wallet.
  if penalties_on and S.cash > 200 and chance(POLICY_CHANCE) then
    local pct = rnd(POLICY_MIN, POLICY_MAX)
    local loss = math.floor(S.cash * (pct / 100))
    S.cash = S.cash - loss
    local hit = "-" .. onions(loss) .. " (" .. pct .. "%)"
    local laws = {
      { "Springfield passes a", "surprise grocery levy.", "Hit: " .. hit },
      { "Mayor hikes the Chicago", "Digital Asset Tax.", "Hit: " .. hit },
      { "Cook County contraband", "fee assessed.", "Hit: " .. hit },
      { "IL Dept of Revenue", "audits you. Back taxes:", hit },
      { "Mugged on the L!", "Lost: " .. hit },
    }
    notify(laws[rnd(1, #laws)])
    return
  end

  -- Jiaming films your onion buy on her iPhone -- pay to delete the footage.
  if penalties_on and S.cash > 100 and chance(SHAKE_CHANCE) then
    local loss, basis = shakedown_20()
    notify({
      "Jiaming filmed your",
      "onion buy on iPhone!",
      "Pay to delete it.",
      "Lost " .. SHAKEDOWN_PCT .. "% of " .. basis .. ":",
      "-" .. onions(loss),
    })
    return
  end

  -- Police chase -- you escape in a Tippi5star Uber, for a price.
  if penalties_on and S.cash > 100 and chance(SHAKE_CHANCE) then
    local loss, basis = shakedown_20()
    notify({
      "Cops on you! You jumped",
      "in a Tippi5star Uber.",
      "Payoff: " .. SHAKEDOWN_PCT .. "% of " .. basis,
      "-" .. onions(loss),
    })
    return
  end

  -- Lobbyist offering a lawyer on retainer (your defense in a Pritzker raid).
  if chance(10) then
    local price = rnd(500, 1200)
    if S.cash >= price then
      local prev = onion.buttons()
      screen({
        "Lobbyist: a lawyer",
        "vs Pritzker raids.",
        "Price " .. onions(price),
        "",
        "SELECT buy  CANCEL pass",
      }, { font = "bold" })
      local btn
      repeat btn = wait_button(prev) until btn == "select" or btn == "cancel"
      if btn == "select" then
        S.cash = S.cash - price
        S.gun = S.gun + 1
        notify({ "Lawyer retained.", "Lawyers: " .. S.gun })
      end
    end
  end

  -- Bigger produce cart (carrying capacity upgrade).
  if chance(10) then
    local price = rnd(150, 400)
    if S.cash >= price then
      local prev = onion.buttons()
      screen({
        "Supplier: bigger cart",
        "+40 crates.",
        "Price " .. onions(price),
        "",
        "SELECT buy  CANCEL skip",
      }, { font = "bold" })
      local btn
      repeat btn = wait_button(prev) until btn == "select" or btn == "cancel"
      if btn == "select" then
        S.cash = S.cash - price
        S.coat = S.coat + 40
        notify({ "Bigger cart!", "Capacity: " .. S.coat .. " crates" })
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Quantity picker (shared by buy / sell)
-------------------------------------------------------------------------------

-- title, unit price, max units, opts {step, bigstep, start}. Returns chosen qty
-- (0 = cancel). For money operations pass unit_price = 1 with bigger steps; the
-- screen then shows a plain Amount instead of Unit/Qty/Cost.
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
      lines[#lines + 1] = "Unit " .. onions(unit_price)
      lines[#lines + 1] = "Qty " .. qty .. " (max " .. max_units .. ")"
      lines[#lines + 1] = "Cost " .. onions(qty * unit_price)
    else
      lines[#lines + 1] = "Amount " .. onions(qty)
      lines[#lines + 1] = "(max " .. onions(max_units) .. ")"
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
    -- Only list goods on sale that you can afford at least one of. Anything you
    -- can't buy (too expensive) is hidden rather than shown as a dead option.
    local rows = {}
    local available = {}
    local on_sale = 0
    for i, d in ipairs(DRUGS) do
      local p = S.market[i] or 0
      if p > 0 then
        on_sale = on_sale + 1
        if p <= S.cash then
          available[#available + 1] = i
          rows[#rows + 1] = d.name .. " " .. onions(p)
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

    list_screen("BUY  free " .. space_left(),
      rows, cursor, "SELECT buy  CANCEL back")
    local btn = wait_button(prev)
    if btn == "up" then cursor = cursor - 1; if cursor < 1 then cursor = #available end
    elseif btn == "down" then cursor = cursor + 1; if cursor > #available then cursor = 1 end
    elseif btn == "cancel" then return
    elseif btn == "select" then
      local i = available[cursor]
      local price = S.market[i]
      local max_afford = math.floor(S.cash / price)
      local max_units = math.min(max_afford, space_left())
      local qty = pick_quantity("Buy " .. DRUGS[i].name, price, max_units)
      if qty > 0 then
        S.cash = S.cash - qty * price
        S.inv[i] = S.inv[i] + qty
        notify({ "Bought " .. qty .. " " .. DRUGS[i].name, "for " .. onions(qty * price) })
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
        local pl = p > 0 and onions(p) or "--"
        rows[#rows + 1] = d.name .. " " .. pl
      end
    end
    if #holdings == 0 then
      notify({ "Your cart is empty.", "Go buy something first." })
      return
    end
    if cursor > #holdings then cursor = #holdings end

    list_screen("SELL",
      rows, cursor, "SELECT sell CANCEL back")
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
          S.cash = S.cash + qty * price
          S.inv[i] = S.inv[i] - qty
          notify({ "Sold " .. qty .. " " .. DRUGS[i].name, "for " .. onions(qty * price) })
        end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Onion Loan: spend real onions for in-game buying power (see request_loan)
-------------------------------------------------------------------------------

local function do_loan()
  local in_match = active_match() ~= nil
  local R = 0
  local prev = onion.buttons()
  while true do
    local ingame = R * LOAN_RATE
    local tax = math.floor(R * TAX_PCT / 100)
    local pot = R - tax
    screen({
      "ONION LOAN",
      in_match and ("Spend " .. R .. " onions") or ("Loan size " .. R .. " (free)"),
      "Buy power +" .. onions(ingame),
      "Debt +" .. onions(ingame),
      in_match and ("Tax " .. tax .. " -> " .. TAX_HANDLE) or "(free play, no charge)",
      in_match and ("Pot " .. pot) or "",
      "UP/DN +-1   LR +-10",
      "SELECT ok   CANCEL back",
    }, { font = "small" })
    local btn = wait_button(prev)
    if btn == "up" then R = math.min(LOAN_MAX_ONIONS, R + 1)
    elseif btn == "down" then R = math.max(0, R - 1)
    elseif btn == "right" then R = math.min(LOAN_MAX_ONIONS, R + 10)
    elseif btn == "left" then R = math.max(0, R - 10)
    elseif btn == "cancel" then return
    elseif btn == "select" then
      if R <= 0 then return end
      local grant = R * LOAN_RATE
      if in_match then
        notify({ "Requesting loan...",
          "Approve the " .. onions(R) .. " payment",
          "on your badge." })
        if request_loan(R) then
          S.cash = S.cash + grant; S.debt = S.debt + grant
          notify({ "Loan approved!",
            "+" .. onions(grant) .. " buying power.",
            "Debt is now " .. onions(S.debt) .. "." })
        else
          notify({ "Loan payment failed.", "No onions were charged." })
        end
      else
        S.cash = S.cash + grant; S.debt = S.debt + grant
        notify({ "Loan granted (free).",
          "+" .. onions(grant) .. " buying power.",
          "Debt is now " .. onions(S.debt) .. "." })
      end
      return
    end
  end
end

-------------------------------------------------------------------------------
-- Bank + loan shark (The Loop only)
-------------------------------------------------------------------------------

local function do_bank()
  local cursor = 1
  local actions = { "Pay debt", "Borrow", "Onion Loan", "Deposit", "Withdraw" }
  local prev = onion.buttons()
  while true do
    -- Cash is in the header. title + 1 status + 5 actions + footer (+header) = 9.
    local lines = {
      "BANK - The Loop",
      "Owe " .. onions(S.debt) .. "  Bank " .. onions(S.bank),
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
      if a == "Pay debt" then
        local max_pay = math.min(S.cash, S.debt)
        -- default to paying the max so SELECT clears as much debt as possible
        local qty = pick_quantity("Pay debt", 1, max_pay,
          { step = 100, bigstep = 1000, start = max_pay })
        if qty > 0 then S.cash = S.cash - qty; S.debt = S.debt - qty
          notify({ "Paid " .. onions(qty) .. " on debt.", "Owe " .. onions(S.debt) }) end
      elseif a == "Borrow" then
        local qty = pick_quantity("Borrow (max 5000)", 1, 5000,
          { step = 100, bigstep = 1000 })
        if qty > 0 then S.cash = S.cash + qty; S.debt = S.debt + qty
          notify({ "Borrowed " .. onions(qty) .. ".", "Owe " .. onions(S.debt) }) end
      elseif a == "Onion Loan" then
        do_loan()
      elseif a == "Deposit" then
        local qty = pick_quantity("Deposit to bank", 1, S.cash,
          { step = 100, bigstep = 1000 })
        if qty > 0 then S.cash = S.cash - qty; S.bank = S.bank + qty
          notify({ "Deposited " .. onions(qty) .. ".", "Bank " .. onions(S.bank) }) end
      elseif a == "Withdraw" then
        local qty = pick_quantity("Withdraw from bank", 1, S.bank,
          { step = 100, bigstep = 1000 })
        if qty > 0 then S.bank = S.bank - qty; S.cash = S.cash + qty
          notify({ "Withdrew " .. onions(qty) .. ".", "Cash " .. onions(S.cash) }) end
      end
    end
  end
end

-------------------------------------------------------------------------------
-- Travel (advances the day)
-------------------------------------------------------------------------------

local function accrue_interest()
  S.debt = math.floor(S.debt * (1 + DEBT_RATE))
  S.bank = math.floor(S.bank * (1 + BANK_RATE))
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

local function main_menu()
  local cursor = 1
  local prev = onion.buttons()
  while not S.over do
    -- Track the best net worth reached this run, for the end-of-month summary.
    local nw_now = net_worth()
    if nw_now > (S.peak or 0) then S.peak = nw_now end
    local in_loop = CITIES[S.city] == BANK_CITY
    local actions = { "Buy", "Sell", "Travel" }
    if in_loop then actions[#actions + 1] = "Bank" end
    actions[#actions + 1] = "Stash"
    actions[#actions + 1] = "Scores"
    -- No "Quit" row: CANCEL quits (and saves) from here, which keeps the menu
    -- within the 9-line panel even in The Loop (Bank + Scores present).
    if cursor > #actions then cursor = #actions end

    -- Cash is in the header. 2 status lines + up to 6 actions = <=8 lines here
    -- (+1 header = <=9 total), each <=23 chars wide.
    local lines = {
      "ONIONWARS  Day " .. S.day .. "/" .. TOTAL_DAYS,
      CITIES[S.city] .. " Owe " .. onions(S.debt),
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
      elseif a == "Bank" then do_bank()
      elseif a == "Stash" then
        local nw = net_worth()
        local pct = math.floor(nw / GOAL_NET * 100)
        if pct < 0 then pct = 0 end
        local rows = {
          "NET WORTH: " .. onions(nw),
          rank_title(nw) .. "  (" .. pct .. "% to goal)",
          "",
        }
        for i, d in ipairs(DRUGS) do
          if S.inv[i] > 0 then rows[#rows + 1] = d.name .. " x" .. S.inv[i] end
        end
        if #rows == 3 then rows[#rows + 1] = "(cart is empty)" end
        notify(rows, { no_header = true })
      elseif a == "Travel" then
        local ended = do_travel()
        if ended then return "ended" end
        save_game()
      elseif a == "Scores" then
        show_leaderboard()
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
  -- liquidate held drugs at current prices into the final score
  local final = net_worth()
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
    "END OF THE MONTH",
    why,
    "Net worth: " .. onions(final),
    "Rank: " .. rank_title(final),
    "Peak: " .. onions(S.peak),
  }
  if final >= GOAL_NET then lines[#lines + 1] = "ONION KINGPIN -- you win!" end
  if is_best then lines[#lines + 1] = "NEW BEST!"
  elseif best then lines[#lines + 1] = "Best: " .. onions(best) end

  -- ONLINE hooks: post to the global high-score board (free play too), and
  -- report into a staked match if one is configured.
  submit_global_score(final)
  report_score(final)

  notify(lines, { no_header = true })
end

-------------------------------------------------------------------------------
-- ONLINE / staked-match hooks (Phase 2 — see ONIONWARS.md)
-------------------------------------------------------------------------------
-- These are deliberately thin. Moving REAL onions (stake in, payout to the
-- winner) requires the oniondao.dev server to build the SPL token transfer and
-- the badge firmware to sign it through the existing transaction-approval flow.
-- Until those server routes exist, these no-op unless a match code is present
-- in NVS (set out-of-band), and they only REPORT scores — they never claim to
-- have moved tokens on their own.

-- Returns the configured match code, or nil for plain single-player.
function active_match()
  if not STAKING_ENABLED then return nil end
  if not onion.kv_get then return nil end
  local code = onion.kv_get("ow_match")
  if code and code ~= "" then return code end
  return nil
end

-- POST the final score to the match coordinator. The server is responsible for
-- ranking players by drugs/net-worth and instructing the Dealer escrow wallet
-- to pay the winner. See ONIONWARS.md for the full contract.
function report_score(final)
  local match = active_match()
  if not match then return end
  if not (onion.http_post and onion.onion_id) then return end
  local wallet = onion.wallet and onion.wallet() or ""
  local body = string.format(
    '{"match":"%s","onionId":%s,"wallet":"%s","score":%d,"day":%d}',
    match, tostring(onion.onion_id()), wallet, math.floor(final), S.day)
  local ok = pcall(function()
    onion.http_post("https://oniondao.dev/api/games/onionwars/score", body,
      { content_type = "application/json", timeout_ms = 8000 })
  end)
  if ok then
    notify({
      "Score sent: " .. match,
      "Pot pays " .. WINNER_PCT .. "% to the",
      "top net worth,",
      TAX_PCT .. "% tax to",
      TAX_HANDLE .. ".",
    })
  end
end

-- Request an Onion Loan of `real_onions` real onions. In a staked match this
-- asks the server to build the real transfer (TAX_PCT to @chicagotax, the rest
-- to the holding/escrow wallet) and push it to the badge for approval through
-- the existing transaction-approval flow; the server credits the loan only once
-- that transfer confirms. Returns true if the request was accepted (HTTP 2xx),
-- false otherwise. In free play there is no match, so the caller handles it.
function request_loan(real_onions)
  local match = active_match()
  if not match then return false end
  if not (onion.http_post and onion.onion_id) then return false end
  local wallet = onion.wallet and onion.wallet() or ""
  local body = string.format(
    '{"match":"%s","onionId":%s,"wallet":"%s","onions":%d,"taxHandle":"%s"}',
    match, tostring(onion.onion_id()), wallet, math.floor(real_onions), TAX_HANDLE)
  local ok, resp = pcall(function()
    return onion.http_post("https://oniondao.dev/api/games/onionwars/loan", body,
      { content_type = "application/json", timeout_ms = 15000 })
  end)
  if ok and type(resp) == "table" and resp.status and resp.status >= 200 and resp.status < 300 then
    return true
  end
  return false
end

-- Post this run's final net worth to the global high-score board. Best-effort
-- and silent: no real onions move, so it runs in free play too. Skips quietly
-- if the badge has no network identity yet. The server keeps each player's best
-- score, keyed by onion id.
function submit_global_score(final)
  if not (onion.http_post and onion.onion_id and onion.onion_id()) then return end
  local wallet = onion.wallet and onion.wallet() or ""
  local body = string.format(
    '{"onionId":%s,"wallet":"%s","score":%d,"day":%d}',
    tostring(onion.onion_id()), wallet, math.floor(final), S.day)
  pcall(function()
    onion.http_post(LEADERBOARD_URL, body,
      { content_type = "application/json", timeout_ms = 8000 })
  end)
end

-- Fetch the top players from the global board. Returns a list of
-- { name, score } (highest first) or nil on any failure. Parses the JSON
-- response with plain Lua patterns (no JSON lib on the badge): the server
-- returns { "players": [ { "name": "...", "score": N, "day": D }, ... ] }.
function fetch_leaderboard()
  if not onion.http_get then return nil end
  local ok, resp = pcall(function()
    return onion.http_get(LEADERBOARD_URL .. "?limit=" .. LEADERBOARD_TOP,
      { timeout_ms = 8000 })
  end)
  if not (ok and type(resp) == "table" and resp.status
          and resp.status >= 200 and resp.status < 300 and resp.body) then
    return nil
  end
  local players = {}
  -- Walk each JSON object; read name/score order-independently within it.
  for obj in resp.body:gmatch("{(.-)}") do
    local name  = obj:match('"name"%s*:%s*"(.-)"')
    local score = tonumber(obj:match('"score"%s*:%s*(%-?%d+)'))
    if score then
      players[#players + 1] = { name = name or "anon", score = score }
    end
  end
  return players
end

-- "Scores" menu screen: pull the global top-N and show a ranked list. Falls
-- back to the local personal best if the board can't be reached. Pages through
-- the list with UP/DOWN so all LEADERBOARD_TOP players fit the 9-line panel.
function show_leaderboard()
  screen({ "LEADERBOARD", "", "Loading top " .. LEADERBOARD_TOP .. "..." },
    { font = "small", no_header = true })
  local players = fetch_leaderboard()
  if not players or #players == 0 then
    local best = tonumber(onion.kv_get and onion.kv_get("ow_best") or "") or nil
    local rows = { "LEADERBOARD", "", "Board unavailable." }
    if best then rows[#rows + 1] = "Your best: " .. onions(best) end
    notify(rows)
    return
  end

  -- No Cash header here, so the budget is: 1 title + PAGE rows + 1 footer = 9.
  local PAGE = 7
  local pages = math.ceil(#players / PAGE)
  local page = 1
  local prev = onion.buttons()
  while true do
    local first = (page - 1) * PAGE
    local rows = { "LEADERBOARD " .. page .. "/" .. pages }
    for i = first + 1, math.min(first + PAGE, #players) do
      local p = players[i]
      local nm = p.name
      if #nm > 9 then nm = nm:sub(1, 9) end
      -- "%2d name(<=9) score" stays within the 22-char line width.
      rows[#rows + 1] = string.format("%2d %-9s %s", i, nm, onions(p.score))
    end
    rows[#rows + 1] = (pages > 1) and "[v] page  [SEL] back" or "[SELECT] back"
    screen(rows, { font = "small", no_header = true })

    local btn = wait_button(prev)
    if btn == "select" or btn == "cancel" then return
    elseif btn == "down" or btn == "right" then page = page % pages + 1
    elseif btn == "up" or btn == "left" then page = (page - 2) % pages + 1
    end
  end
end

-------------------------------------------------------------------------------
-- Entry
-------------------------------------------------------------------------------

local function intro_if_new(is_resume)
  if is_resume then
    notify({ "ONIONWARS", "Resuming run...",
      "Day " .. S.day .. " - " .. CITIES[S.city] })
  elseif active_match() then
    notify({
      "ONIONWARS",
      "Chicago. Staked match.",
      "Entry " .. onions(ENTRY_FEE) .. " paid.",
      "Win: top net worth gets",
      WINNER_PCT .. "% of the pot.",
      TAX_PCT .. "% tax to " .. TAX_HANDLE,
    })
  else
    notify({
      "ONIONWARS - 30 days",
      "Goal: " .. onions(GOAL_NET) .. " net",
      "worth = Onion Kingpin.",
      "Pay the Dealer FAST:",
      "debt grows 10%/day!",
      "Buy low, sell high.",
    })
  end
end

-- Title splash shown at launch: big "ONION WARS" logo, then waits for a press.
local function splash()
  if onion.display_begin then onion.display_begin() end
  onion.display_lines({ "ONION", "WARS" }, 64, 48, 42, { clear = true, font = "large" })
  onion.display_lines({ "Chicago", "Press SELECT to play" }, 8, 120, 20,
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

  intro_if_new(is_resume)
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
