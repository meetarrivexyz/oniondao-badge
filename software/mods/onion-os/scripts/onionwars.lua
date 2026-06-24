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

local TOTAL_DAYS   = 2
local START_CASH   = 2000
local START_DEBT   = 5500
local START_HP     = 20
local START_COAT   = 100
local DEBT_RATE    = 0.10   -- loan shark interest per day
local BANK_RATE     = 0.05  -- savings interest per day
local SCREEN_W      = 264
local SCREEN_H      = 176

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

-- Onion Loan: spend real onions to take out a bigger in-game loan (more buying
-- power). Each real onion buys LOAN_RATE in-game onions of cash, added to your
-- in-game debt (same 10%/day mechanics). The real onions split like the pot:
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

-------------------------------------------------------------------------------
-- Save / load (single compact NVS key, kv_set value limit is ~1024 bytes)
-------------------------------------------------------------------------------

local SAVE_KEY = "ow_save"

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

-- Draw a full screen in one batched e-paper refresh.
local function screen(lines, opts)
  opts = opts or {}
  local x  = opts.x or 6
  local y  = opts.y or TOP_Y
  local lh = opts.lh or LH
  local font = opts.font or "small"
  if onion.display_begin then
    onion.display_begin()
    onion.display_lines(lines, x, y, lh, { clear = true, font = font })
    onion.display_commit()
  else
    onion.display_lines(lines, x, y, lh, { clear = true, font = font })
  end
end

-- A blocking message screen: shows lines, waits for SELECT or CANCEL.
local function notify(lines)
  local rows = {}
  for _, l in ipairs(lines) do rows[#rows + 1] = l end
  rows[#rows + 1] = ""
  rows[#rows + 1] = "[SELECT] continue"
  screen(rows, { font = "small" })
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
  S.market = {}
  for i, d in ipairs(DRUGS) do
    if chance(80) then
      S.market[i] = rnd(d.low, d.high)
    else
      S.market[i] = 0 -- not available here today
    end
  end

  -- Occasional price shocks make some runs lucrative.
  if chance(18) then
    -- Demand spike: price spikes WAY up.
    local i = rnd(1, #DRUGS)
    S.market[i] = math.floor(DRUGS[i].high * (1.5 + math.random()))
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
    S.market[i] = math.max(1, math.floor(DRUGS[i].low / 3))
    local n = DRUGS[i].name
    local down = {
      { "FDA recall flood!", n .. " cheap!" },
      { "Cook County auction!", n .. " crashes!" },
      { "Bumper harvest!", n .. " glut!" },
    }
    local m = down[rnd(1, #down)]
    events[#events + 1] = m[1]; events[#events + 1] = m[2]
  end
  return events
end

-------------------------------------------------------------------------------
-- Random travel events
-------------------------------------------------------------------------------

-- A JB Pritzker Law raid (the Governor's new digital-asset crackdown). You
-- defend with lawyers on retainer (internally still S.gun) or run; raids cost
-- standing (S.hp). Returns once resolved (may end the game if standing hits 0).
local function raid_encounter()
  local agents = rnd(1, 3)
  while agents > 0 and S.hp > 0 do
    local prev = onion.buttons()
    screen({
      "JB PRITZKER LAW!",
      agents .. " state agents want",
      "to seize your onions.",
      "Standing " .. S.hp .. "  Lwyr " .. S.gun,
      "",
      S.gun > 0 and "SELECT Lawyer up" or "(no lawyer)",
      "CANCEL Ditch & run",
    }, { font = "bold" })
    local btn = wait_button(prev)

    if btn == "select" and S.gun > 0 then
      if chance(60) then
        agents = agents - 1
        notify({ "Your lawyer got one", "charge thrown out!", "Agents left: " .. agents })
      else
        local dmg = rnd(1, 5)
        S.hp = S.hp - dmg
        notify({ "They slapped you with", "fines & bad press.", "-" .. dmg .. " standing (now " .. S.hp .. ")" })
      end
    elseif btn == "cancel" then -- run
      if chance(65) then
        notify({ "You ditched the cart", "and slipped them. Phew." })
        return
      else
        local dmg = rnd(1, 4)
        S.hp = S.hp - dmg
        notify({ "Cited on the way out.", "-" .. dmg .. " standing." })
      end
    end
    -- any other button just redraws the raid prompt

    if S.hp <= 0 then return end
  end
  if agents <= 0 and S.hp > 0 then
    local loot = rnd(200, 1500)
    S.cash = S.cash + loot
    notify({ "Case dismissed!",
      "Countersued, won " .. onions(loot) })
  end
end

local function travel_events()
  -- Pritzker-raid chance scales with how much contraband you are carrying.
  local risk = 10 + math.floor(carried() / 10)
  if risk > 45 then risk = 45 end
  if carried() > 0 and chance(risk) then
    raid_encounter()
    if S.hp <= 0 then return end
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

  -- Policy / law event: Springfield & City Hall skim a % of your wallet.
  if S.cash > 200 and chance(16) then
    local pct = rnd(10, 30)
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

  -- Lobbyist offering a lawyer on retainer (your defense in a Pritzker raid).
  if chance(10) then
    local price = rnd(500, 1200)
    if S.cash >= price then
      local prev = onion.buttons()
      screen({
        "Lobbyist: lawyer on",
        "vs Pritzker raids.",
        "Price " .. onions(price),
        "Cash " .. onions(S.cash),
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
        "Cash " .. onions(S.cash),
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

-- title lines, unit price, max units. Returns chosen qty (0 = cancel).
local function pick_quantity(title, unit_price, max_units)
  if max_units <= 0 then
    notify({ title, "Nothing to do here." })
    return 0
  end
  local qty = 0
  local prev = onion.buttons()
  while true do
    screen({
      title,
      "Unit " .. onions(unit_price),
      "Qty " .. qty .. " (max " .. max_units .. ")",
      "Cost " .. onions(qty * unit_price),
      "",
      "UP/DN +-1   LR +-10",
      "SELECT ok   CANCEL back",
    }, { font = "small" })
    local btn = wait_button(prev)
    if btn == "up" then qty = math.min(max_units, qty + 1)
    elseif btn == "down" then qty = math.max(0, qty - 1)
    elseif btn == "right" then qty = math.min(max_units, qty + 10)
    elseif btn == "left" then qty = math.max(0, qty - 10)
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
  lines[#lines + 1] = ""
  lines[#lines + 1] = footer
  screen(lines, { font = "small" })
end

local function do_buy()
  local cursor = 1
  local prev = onion.buttons()
  while true do
    local rows = {}
    local available = {}
    for i, d in ipairs(DRUGS) do
      local p = S.market[i] or 0
      if p > 0 then
        available[#available + 1] = i
        rows[#rows + 1] = d.name .. " " .. onions(p)
      end
    end
    if #available == 0 then
      notify({ "Nothing for sale today.", "Try another borough." })
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

    list_screen("SELL  cash " .. onions(S.cash),
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
    -- 3 status lines + 5 actions + footer = 9 lines.
    local lines = {
      "BANK - The Loop",
      "Cash " .. onions(S.cash) .. " Owe " .. onions(S.debt),
      "Bank " .. onions(S.bank),
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
        local qty = pick_quantity("Pay debt", 1, max_pay)
        if qty > 0 then S.cash = S.cash - qty; S.debt = S.debt - qty
          notify({ "Paid " .. onions(qty) .. " on debt.", "Owe " .. onions(S.debt) }) end
      elseif a == "Borrow" then
        local qty = pick_quantity("Borrow (max 5000)", 1, 5000)
        if qty > 0 then S.cash = S.cash + qty; S.debt = S.debt + qty
          notify({ "Borrowed " .. onions(qty) .. ".", "Owe " .. onions(S.debt) }) end
      elseif a == "Onion Loan" then
        do_loan()
      elseif a == "Deposit" then
        local qty = pick_quantity("Deposit to bank", 1, S.cash)
        if qty > 0 then S.cash = S.cash - qty; S.bank = S.bank + qty
          notify({ "Deposited " .. onions(qty) .. ".", "Bank " .. onions(S.bank) }) end
      elseif a == "Withdraw" then
        local qty = pick_quantity("Withdraw from bank", 1, S.bank)
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
    local in_loop = CITIES[S.city] == BANK_CITY
    local actions = { "Buy", "Sell", "Travel" }
    if in_loop then actions[#actions + 1] = "Bank" end
    actions[#actions + 1] = "Stash"
    actions[#actions + 1] = "Quit"
    if cursor > #actions then cursor = #actions end

    -- 3 status lines + up to 6 actions = <=9 lines, each <=22 chars wide.
    local lines = {
      "ONIONWARS  Day " .. S.day .. "/" .. TOTAL_DAYS,
      CITIES[S.city] .. "  HP " .. S.hp,
      "Cash " .. onions(S.cash) .. " Owe " .. onions(S.debt),
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
        local rows = { "NET WORTH: " .. onions(net_worth()), "" }
        for i, d in ipairs(DRUGS) do
          if S.inv[i] > 0 then rows[#rows + 1] = d.name .. " x" .. S.inv[i] end
        end
        if #rows == 2 then rows[#rows + 1] = "(cart is empty)" end
        notify(rows)
      elseif a == "Travel" then
        local ended = do_travel()
        if ended then return "ended" end
        save_game()
      elseif a == "Quit" then
        save_game(); return "quit"
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
  if S.hp <= 0 then why = "State shut you down."
  else why = "Out of time. Game over." end

  -- Persist a personal best so repeat plays have a target.
  local best = tonumber(onion.kv_get and onion.kv_get("ow_best") or "") or nil
  local is_best = (not best) or (final > best)
  if is_best and onion.kv_set then onion.kv_set("ow_best", tostring(final)) end

  clear_save() -- next launch starts a new run

  local lines = {
    "=== GAME OVER ===",
    why,
    "",
    "Final net worth:",
    "  " .. onions(final),
  }
  if best then lines[#lines + 1] = "Previous best: " .. onions(best) end
  if is_best then lines[#lines + 1] = ">> NEW PERSONAL BEST <<" end

  -- ONLINE hook: report this score to a staked match if one is configured.
  report_score(final)

  notify(lines)
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
      "ONIONWARS",
      "Chicago. Free play.",
      "You owe " .. onions(START_DEBT) .. ".",
      onions(START_CASH) .. " to start.",
      TOTAL_DAYS .. " days. Buy low,",
      "sell high, dodge law.",
    })
  end
end

local function run()
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
