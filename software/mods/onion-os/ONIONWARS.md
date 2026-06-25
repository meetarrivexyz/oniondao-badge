# OnionWars

A badge-native, onion-themed take on the classic 1984 trading game, denominated in
**onions** (the OnionDAO Onion token) instead of dollars. The game ships as a
single Lua script, `scripts/onionwars.lua`, that runs on Onion OS through the
`onion.*` scripting API — e-paper display, the six-button matrix, NVS save
state, and (for the staked multiplayer mode) the badge's HTTP/MQTT bridge.

## Phase 1 — single-player (shipped)

Everything in `scripts/onionwars.lua` today is self-contained and works on any
badge running Onion OS with the Path B Lua additions (`display_begin`,
`display_commit`, `kv_set`, `kv_get`, `millis`, `buttons`).

The loop is the classic one, with onions as the currency:

- **2 days.** Start with `O2,000` cash and a `O5,500` debt to the Dealer
  (the loan shark). Debt grows 10%/day; bank savings grow 5%/day.
- **6 onion-themed goods** (Scallions, Shallots, Red Onions, Vidalia, Garlic,
  Black Garlic — cheapest to priciest), each with a price range. Every
  neighborhood regenerates a fresh market each day, and
  price shocks ("addicts paying through the nose", "Cook County seizure
  auction") create the buy-low/sell-high swings.
- **6 Chicago neighborhoods** (The Loop, South Side, West Side, Wicker Park,
  Englewood, Lincoln Park). The Loop (downtown) has the **Dealer & Bank**
  (pay debt, borrow in-game, take out a real-onion **Onion Loan**, deposit/
  withdraw savings).
- **Onion Loan.** Spend real onions for more in-game buying power: each real
  onion buys `LOAN_RATE` (100) in-game onions of cash, added to your in-game
  debt (same 10%/day mechanics). The real onions split 20% to `@chicagotax` and
  the rest to the holding/escrow pot — so taking a loan also grows the prize.
  Settled server-side (see Phase 2); simulated in free play.
- **Produce cart** capacity limits how much you can carry; a supplier sometimes
  offers a `+40`-crate upgrade.
- **JB Pritzker Law raids — a money-vs-time choice.** The Governor's
  digital-asset crackdown catches you mid onion buy (chance scales with how much
  you're carrying). You pick a defense:
  - **Super lawyer (dev):** high fee, 0 days lost, keep your onions, always wins.
  - **Bob (mid lawyer):** mid fee, 2 days in County jail, keep your onions.
  - **Public defender:** free, 4–6 days in jail, keep your onions — but a small
    chance you're *held indefinitely* (game over).
  - **Ditch cart & run:** free and no days lost, but you drop **all** your onions
    (keep your cash); sometimes you're caught anyway.
  - A **lawyer on retainer** (bought from a lobbyist) is a free instant win.
  Jail days hurt because debt keeps compounding while you're locked up, and the
  days come out of your 15. So it's keep-onions-but-pay-money-and-time vs
  keep-cash-but-lose-the-onions.
- **Policy/law events.** Travel can trigger a Chicago/Illinois policy hit that
  skims 10–30% of your wallet (cash) — e.g. "Gov. JB Pritzker signs a new
  digital-asset law", a Chicago Digital Asset Tax hike, a Cook County contraband
  fee, an IL Dept of Revenue audit, or a plain mugging on the L. Free drops and
  lobbyists (lawyers) and produce-cart suppliers round out the travel events.
- **Score = net worth** (`cash + bank + drug value − debt`). A personal best is
  kept in NVS (`ow_best`).

**Important:** in Phase 1 every balance is an *in-game ledger* saved to NVS. No
real Onion tokens move. It is a game economy, not a wallet transaction.

### Controls

| Button | Action |
|--------|--------|
| UP / DOWN | move cursor / quantity ±1 |
| LEFT / RIGHT | quantity ±10 |
| SELECT | confirm |
| CANCEL | back out one screen; on the main menu, save & quit |

### Save format

A single NVS key, `ow_save`, holds a compact pipe/comma-delimited blob well
under the 1 KB `kv_set` limit:

```
day|city|cash|debt|bank|hp|coat|gun|over|inv0,inv1,inv2,inv3,inv4,inv5
```

Launching resumes an unfinished run; finishing a run clears `ow_save` so the
next launch starts fresh, and updates `ow_best`.

## Phase 2 — staked match with a real onion pot (design, not yet built)

The goal: **it costs `100` real onions to play. Each entry moves into the
Dealer escrow wallet. At the end the pot is split — `80%` to the player with
the highest net worth in OnionDAO, and `20%` as the City of Chicago Digital
Asset Tax, paid to the OnionDAO handle `@chicagotax`.**

The numbers are fixed in `scripts/onionwars.lua` as `ENTRY_FEE = 100`,
`WINNER_PCT = 80`, `TAX_PCT = 20`, and `TAX_HANDLE = "@chicagotax"`, and they
must match the server's match configuration. The server resolves the
`@chicagotax` handle to its OnionDAO wallet at settlement.

This *cannot* be done from Lua alone, and it does not need new core
`oniondao.dev` routes either — the **OnionDAO Escrow Accounts API already does
exactly this** (see `API.md` → "Escrow Accounts"). The missing piece is a small
**OnionWars coordinator** service that holds the secrets and drives the escrow
API; the badge talks only to the coordinator.

### Why a coordinator (the badge can't hold secrets)

The escrow routes require `ONION_EXTERNAL_API_KEY` and the per-account
`accountSecret` — **server secrets that must never ship on a badge.** So:

- The **coordinator** (a tiny server app) holds those secrets and is the only
  thing that calls `oniondao.dev` escrow routes.
- The **badge** calls only the coordinator's own simple routes (the
  `/api/games/onionwars/*` URLs in `onionwars.lua`). The coordinator base URL is
  wherever you host it — it does not have to be `oniondao.dev`.
- The **player** approves their own buy-in in `/portal/onions`; if they have a
  linked badge, that approval is a badge-signed token transfer into escrow
  custody via the existing badge transaction flow. No money moves without the
  user's approval.

### How the coordinator maps to the escrow API

- **The pot = one escrow account.** Coordinator calls
  `POST /api/public/onions/escrow/accounts` (external bearer) once per match,
  with `externalId = <matchCode>` (idempotent), and stores the returned
  `accountSecret`.
- **Buy-in / Onion Loan = an escrow deposit.**
  `POST /api/public/onions/escrow/accounts/{id}/deposits`
  `{ "username": "<player>", "amount": 100, "externalId": "buyin_<player>_<match>" }`.
  The user approves in `/portal/onions`; a linked badge signs the token transfer
  to custody. The escrow callback (`status:"completed"`) tells the coordinator
  the buy-in landed.
- **Payouts = escrow transfers.** At settlement the coordinator ranks players by
  reported net worth and makes two transfers from the pot:
  `POST /api/public/onions/escrow/accounts/{id}/transfers`
  `{ "recipientUsername": "<winner>",   "amount": <80% of pot>, "currencyMode":"auto", "externalId":"payout_winner_<match>" }`
  `{ "recipientUsername": "chicagotax", "amount": <20% of pot>, "currencyMode":"auto", "externalId":"tax_<match>" }`.
  Users are addressed by **handle/username** (the API forbids raw wallet
  addresses), so `@chicagotax` is just `recipientUsername: "chicagotax"`.

Scores have no core API route, so the coordinator owns the score table (the
badge POSTs its final net worth to the coordinator). The coordinator should
sanity-check scores (cap payout at pot size, require a minimum number of played
days, flag impossible jumps) before paying out.

### Lifecycle

```
1. CREATE   coordinator opens match "CHI25":
            -> POST /api/public/onions/escrow/accounts  (external bearer)
               { "requester":"onionwars", "externalId":"CHI25",
                 "name":"OnionWars CHI25 pot" }
            -> store the returned accountSecret for this match.

2. JOIN     badge -> coordinator: POST /api/games/onionwars/join
               { "match":"CHI25", "onionId":<id> }
            coordinator -> escrow deposit (amount = ENTRY_FEE = 100) for the
               player's username; user approves in /portal/onions (linked badge
               signs the token transfer to custody).
            On the "completed" escrow callback the coordinator marks the player
               joined and (out of band) sets the badge NVS key "ow_match"=CHI25
               so onionwars.lua knows it is a staked run.

3. PLAY     onionwars.lua runs the normal Chicago loop (2,000 cash / 5,500 debt).

3b. LOAN    badge -> coordinator: POST /api/games/onionwars/loan
               { "match":"CHI25", "onionId":<id>, "onions":<n> }
            coordinator -> escrow deposit (amount = n) for the player. On
               confirm (HTTP 2xx) the badge credits cash += n*LOAN_RATE and adds
               the same to in-game debt. In free play the loan is simulated.

4. REPORT   on game over: badge -> coordinator POST /api/games/onionwars/score
               { "match":"CHI25", "onionId":<id>, "score":<netWorth>, "day":<d> }

5. SETTLE   after the deadline the coordinator ranks by net worth and makes the
            two escrow transfers above (80% winner, 20% chicagotax), then clears
            "ow_match" on every participating badge.
```

### What the badge does directly (real OnionDAO API)

The badge's one real-onion action — the **Onion Loan** — uses the real API
directly, no coordinator:

- `request_loan(n)` creates a transfer with
  `POST /api/public/onions/requests` (External bearer), body
  `{ "type":"transfer", "username":<player>, "recipientUsername":"onionwars",
  "amount":n, "requester":"onionwars", "externalId":..., "note":... }`,
  then polls `GET /api/public/onions/requests/{id}` until `status:"completed"`.
  The player approves the transfer in `/portal/onions`; a linked badge signs it.
  The badge credits the in-game loan **only** on `completed`.
- This needs the `ONION_EXTERNAL_API_KEY` as a bearer token. It is read from NVS
  key **`ow_apikey`** (never hardcoded); if absent, the loan silently can't run.
  ⚠️ Putting the external key on a badge lets that badge create transfer requests
  for any user, so treat it as a trusted-event/kiosk setting — or front it with a
  coordinator (below) that injects the key server-side.

### Coordinator (entry fee, payouts, scoring)

The pot and payouts can't be badge-driven (they need the per-account
`accountSecret`). A small **OnionWars coordinator** holds the secrets and uses
the escrow API:

- **Buy-in:** escrow **deposit** of `ENTRY_FEE` for each joining player; set the
  badge's `ow_match` NVS key (MQTT or serial) once it confirms.
- **Settle:** rank players by net worth, then two escrow **transfers** — 80% to
  the winner, 20% to `chicagotax` — and clear `ow_match`.
- **Scoring:** there is no score route in the core API, so the coordinator owns
  the score table (the badge POSTs its final net worth to the coordinator).

### Hooks in `onionwars.lua`

All gated behind `STAKING_ENABLED` (false today) **and** an `ow_match` code in
NVS, so in free play the game makes no network calls:

- `active_match()` — returns the `ow_match` NVS value, or `nil`.
- `onion_transfer(recipient, amount, note, ext)` — the real Onion Requests
  create-and-poll helper described above.
- `request_loan(real_onions)` — transfers the loan amount to `POT_HANDLE` via
  `onion_transfer`; the badge credits buying power only when it returns `true`.

(Score reporting was removed from the badge — there is no API route for it, and
it belongs on the coordinator.)

### Not built yet

- The **coordinator service** (escrow deposits/transfers, score table, settlement).
- Provisioning **`ow_apikey`** onto badges, and **`ow_match`** at join time.
- A **global free-play leaderboard** — no core API route exists; would live on
  the coordinator or a new core route. Intentionally absent today.
