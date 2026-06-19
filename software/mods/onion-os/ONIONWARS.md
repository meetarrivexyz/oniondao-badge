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
- **FDA raids, standing, and lawyers.** Onions are food, so the enforcer is the
  FDA acting on "Sec. Kennedy's new food bill," not the cops. Carrying more
  contraband produce raises the raid chance. You start with `20` standing;
  defend with a lawyer on retainer (bought from a lobbyist) or ditch the cart
  and run. Lose all your standing and the FDA shuts you down (game over).
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

This *cannot* be done from Lua alone, and the game does not pretend otherwise.
On this badge, real SPL-token movement only happens when the **server builds a
Solana transaction and the badge firmware signs it** through the existing
transaction-approval flow (see `software/mods/onion-os/README.md` →
"Solana Key Custody" and the `oniondao/badge/{onionId}/transaction/request`
MQTT topic). So Phase 2 is mostly server + firmware work, with thin Lua hooks.

### Trust model

- The **Dealer escrow wallet** is a server-controlled Onion token account. It
  is the single source of truth for the pot. Players never send onions to each
  other — only player→escrow (stake) and escrow→winner (payout).
- The **server** ranks players and authorizes the two payout transfers (80% to
  the winner, 20% Chicago Digital Asset Tax to `@chicagotax`). The badge only
  ever signs *its own* 100-onion stake-in transfer, which it shows the player
  for approval first. This keeps the existing "badge signs, user approves"
  custody guarantee intact.
- Scores are reported by badges but **settled by the server**, which should
  cross-check reported net worth against the stake/score history to resist a
  badge lying about its final holdings (e.g. cap payout at pot size, require a
  minimum number of reported travel days, flag impossible net-worth jumps).

### Lifecycle

```
1. CREATE   organizer asks server to open match "VEGAS25":
            POST /api/games/onionwars/match
            { "code":"CHI25", "stake":100, "deadline": <unix>,
              "split":{ "winnerPct":80, "taxPct":20, "taxHandle":"@chicagotax" } }
            -> server returns the Dealer escrow wallet address.

2. JOIN     each badge pays the 100-onion entry fee:
            POST /api/games/onionwars/join
            { "match":"CHI25", "onionId":<id>, "wallet":"<pubkey>" }
            -> server builds a stake-in transfer (player ATA -> escrow ATA,
               amount = 100) and pushes it to the badge on
               oniondao/badge/{onionId}/transaction/request.
            -> badge shows the approval popup, signs, server submits.
            -> server marks the player joined once the transfer confirms,
               and (out of band) writes the match code into the badge's NVS
               key "ow_match" so onionwars.lua knows it is a staked run.

3. PLAY     onionwars.lua runs the normal single-player Chicago loop. The badge
            already has its in-game 2,000 cash / 5,500 debt to play with.

3b. LOAN    (optional, any time during play) the player can take out an Onion
            Loan for more in-game buying power, paying real onions:
            POST /api/games/onionwars/loan
            { "match":"CHI25", "onionId":<id>, "wallet":"<pubkey>",
              "onions":<realOnions>, "taxHandle":"@chicagotax" }
            -> server builds the real transfer and pushes it to the badge for
               approval (same transaction-approval flow as JOIN), splitting it:
                 - taxPct (20%) -> @chicagotax,
                 - the rest      -> the holding (escrow) wallet, growing the pot.
            -> once the transfer confirms (server returns HTTP 2xx), the badge
               credits the loan: in-game cash += onions x LOAN_RATE, and the
               same amount is added to in-game debt (normal 10%/day interest).
            In free play (no match) the loan is simulated and no onions move.

4. REPORT   on game over the badge posts its final net worth:
            POST /api/games/onionwars/score
            { "match":"CHI25", "onionId":<id>, "wallet":"<pubkey>",
              "score":<netWorth>, "day":<lastDay> }

5. SETTLE   after the deadline (or once all players have reported), the server
            ranks by net worth and splits the pot (sum of all 100-onion
            entries):
              - 80% -> one escrow->winner transfer to the highest net worth
                       in OnionDAO,
              - 20% -> one escrow->tax transfer (City of Chicago Digital Asset
                       Tax) to the OnionDAO handle @chicagotax's wallet.
            It then clears the "ow_match" key on every participating badge.
```

### Endpoints the server (`oniondao.dev`) needs to add

| Route | Body | Server responsibility |
|-------|------|----------------------|
| `POST /api/games/onionwars/match` | `code, stake (100), deadline, split` | create match, return escrow wallet |
| `POST /api/games/onionwars/loan`  | `match, onionId, wallet, onions, taxHandle` | build + push the loan transfer (20% to @chicagotax, rest to holding/escrow); credit on confirm |
| `POST /api/games/onionwars/join`  | `match, onionId, wallet` | build + push stake-in transfer; record join on confirm |
| `POST /api/games/onionwars/score` | `match, onionId, wallet, score, day` | record reported score (validated) |
| `GET  /api/games/onionwars/match/{code}` | – | players, pot size, deadline, status, winner |

The stake-in and payout transfers reuse the **existing** badge transaction
flow; no new firmware signing path is required. The only firmware/Lua-side
need is a way for the server to set the `ow_match` NVS key on a linked badge
(either an MQTT command on the badge's existing topic space, or a serial/
config command), so the game knows it is a staked run.

### Hooks already in `onionwars.lua`

The game uses thin hooks that no-op for plain single-player and only activate
when a match code is present in NVS:

- `active_match()` — returns the `ow_match` NVS value, or `nil`.
- `report_score(final)` — at game over, when a match is active and
  `onion.http_post` exists, POSTs the final score to
  `/api/games/onionwars/score`. It **only reports** — it never moves tokens.
- `request_loan(real_onions)` — when the player takes an Onion Loan in a match,
  POSTs to `/api/games/onionwars/loan` and returns `true` only on HTTP 2xx. The
  badge credits the in-game loan **only** if this returns true, so a failed or
  declined payment never grants buying power. The actual onion transfer (and
  the 20%/rest split) is built and submitted by the server.

This keeps the on-chain authority server-side while leaving the badge game
ready to plug into a staked match the moment the server routes exist.
