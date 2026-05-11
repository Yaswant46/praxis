# Praxis — Scoring Rules

Every rule in this file is what the engine in `app.html` actually applies. **The same decision (same case, same field, same option) gives every team the identical metric delta.** Team outcomes only diverge because team choices diverge. There's no randomness.

The engine source of truth:

- `DECISION_IMPACTS` — per-decision impacts (this file's tables 1–3)
- `CB_BANK_A` / `CB_BANK_B` / `CB_BANK_DEMO` — curveball impacts (this file's tables 4–6)
- `_scoringNormaliseScore` — round score formula (table 7)

If you change a number here, mirror it in `app.html` (and vice versa).

---

## Metric vocabulary

The six numbers the engine tracks for every team every round:

| Code              | Display label    | Units                                        |
|-------------------|------------------|----------------------------------------------|
| `revenue`         | Monthly revenue  | ₹ Cr                                         |
| `grossMargin`     | Gross margin     | %                                            |
| `cashRunway`      | Cash runway      | months                                       |
| `marketShare`     | Market share     | 0–100 index                                  |
| `productHealth`   | Product health   | 0–100 index                                  |
| `teamCapability`  | Team capability  | 0–100 index                                  |

Starting metrics per case (Round 1 baseline; same for every team):

| Case   | revenue | grossMargin | cashRunway | marketShare | productHealth | teamCapability |
|--------|--------:|------------:|-----------:|------------:|--------------:|---------------:|
| VOLTA  | 16.8    | -5.8        | 22         | 42          | 58            | 65             |
| ARC    | 6.9     | +4.2        | 24         | 52          | 72            | 74             |
| Demo   | 1.1     | -12         | 11         | 18          | 45            | 60             |

---

## Table 1 — VOLTA Motors: decision impacts

### Engineering — `eng_priority` (primary engineering priority this quarter)

| # | Option                                                | Δ revenue | Δ margin | Δ runway | Δ share | Δ product | Δ team |
|---|-------------------------------------------------------|---------:|--------:|--------:|-------:|---------:|------:|
| 0 | Resolve BLE memory leak (VoltaOS stability)           | −2       |         |         | −1     | **+8**   | +2    |
| 1 | Accelerate Fast-Charge EVSE integration               | +5       | −1      | −1      |         | +2       |       |
| 2 | Ship Fleet Management API for B2B                     | **+7**   | −2      |         | +2     | −1       |       |
| 3 | Begin VoltaOS 2.0 architecture (Edge Gen 2)           |          |         | −1      |        | −2       | **+5**|
| 4 | Focus on Core Maintenance & bug reduction             | −1       | +1      |         |        | +5       | −1    |

### Manufacturing — `mfg_hosur` (Hosur contract manufacturing decision)

| # | Option                                                  | Δ revenue | Δ margin | Δ runway | Δ share | Δ product | Δ team |
|---|---------------------------------------------------------|---------:|--------:|--------:|-------:|---------:|------:|
| 0 | Invest ₹2.2 Cr to fix Hosur quality                     |          | −1      | −2      |        | +6       |       |
| 1 | Maintain as-is, accept warranty                         |          | −3      | +1      |        | −3       |       |
| 2 | Reduce Hosur volume 50%                                 | −3       | +2      | +1      |        |          |       |
| 3 | Exit Hosur, expand Pune (₹8.5 Cr capex)                 |          | +1      | −4      |        | +4       | +1    |

### Supply Chain — `sc_battery` (cell procurement strategy)

| # | Option                                                  | Δ margin | Δ runway |
|---|---------------------------------------------------------|--------:|--------:|
| 0 | Full spot market                                        | +1      |         |
| 1 | 50% forward + 50% spot                                  | +2      | −1      |
| 2 | 100% forward (full hedge)                               | +4      | −3      |

### Supply Chain — `sc_chipaxis` (vendor concentration response)

| # | Option                                                  | Δ margin | Δ runway | Δ product | Δ team |
|---|---------------------------------------------------------|--------:|--------:|---------:|------:|
| 0 | No action                                               |         |         |          |       |
| 1 | Qualify alternate SoC (6-mo project)                    |         | −1      | +1       | +3    |
| 2 | In-house SoC track (18-mo)                              |         | −3      | −1       | **+5**|
| 3 | Renegotiate volume commitment                           | +2      | +1      |          |       |

### Commercial — `com_edge` (Edge pricing decision)

| # | Option                                                  | Δ revenue | Δ margin | Δ share |
|---|---------------------------------------------------------|---------:|--------:|-------:|
| 0 | Hold ₹1,42,000                                          |          |         |        |
| 1 | +₹5K (test elasticity)                                  | +1       | +3      | −2     |
| 2 | −₹5K (defend against ArcMotion)                         | +2       | −3      | +3     |
| 3 | Launch B2B fleet variant                                | +4       | −2      | +2     |

### Commercial — `com_go` (Go volume strategy)

| # | Option                                                  | Δ revenue | Δ margin | Δ runway | Δ share |
|---|---------------------------------------------------------|---------:|--------:|--------:|-------:|
| 0 | Hold volume and pricing                                 |          |         |         |        |
| 1 | Reduce Go, focus Edge                                   | −2       | +2      |         |        |
| 2 | Expand Go to 5 cities (₹3.2 Cr dealer)                  | +5       |         | −2      | +3     |
| 3 | Drop Go price −₹5K                                      |          | −3      |         | +3     |

### People — `ppl_retention`

| # | Option                                                  | Δ runway | Δ product | Δ team |
|---|---------------------------------------------------------|--------:|---------:|------:|
| 0 | ESOP acceleration (₹1.8 Cr/yr)                          | −2      |          | +5    |
| 1 | IIT Bombay structured learning (₹60L/yr)                | −1      | +1       | +4    |
| 2 | Hybrid work policy (engineering pushback)               |         | −1       | −2    |
| 3 | Both ESOP + IIT Bombay                                  | −3      | +1       | **+8**|
| 4 | No specific intervention                                |         | −1       | −3    |

---

## Table 2 — ARC Motors: decision impacts

### Product Direction — `pd_path` (Nimbus development path)

| # | Option                                              | Δ revenue | Δ runway | Δ share | Δ product | Δ team |
|---|-----------------------------------------------------|---------:|--------:|-------:|---------:|------:|
| 0 | Hold Course (current spec)                          | −2       |         | −3     | −2       |       |
| 1 | Add App + Display (+4 mo)                           |          | −2      | +2     | +3       |       |
| 2 | Add App + Display + Fast-charge (+6 mo)             |          | −4      | +3     | +5       |       |
| 3 | Full Parity (+9 mo)                                 |          | −7      | +4     | +6       |       |
| 4 | Pause and reassess                                  | −1       |         | −2     |          | +1    |

### Product Direction — `pd_comms`

| # | Option                                              | Δ runway | Δ share | Δ product | Δ team |
|---|-----------------------------------------------------|--------:|-------:|---------:|------:|
| 0 | Stay silent                                         |         | −1     |          |       |
| 1 | Signal to dealers only                              |         |        |          | +1    |
| 2 | Announce delay publicly                             |         | −2     |          | −2    |
| 3 | Accelerate Nimbus PR                                | −1      | +2     | −1       |       |

### Feature Prioritisation — `fp_top` (highest priority feature)

| # | Option                                              | Δ runway | Δ share | Δ product |
|---|-----------------------------------------------------|--------:|-------:|---------:|
| 0 | Not adapting — hold spec                            |         |        | −2       |
| 1 | Companion App + Gamification (₹3.2 Cr)              | −1      | +1     | +3       |
| 2 | 7-inch Display (₹1.8 Cr)                            | −1      |        | +2       |
| 3 | Fast-Charge BMS revision (₹5.4 Cr)                  | −3      | +2     | +4       |
| 4 | Removable Battery frame redesign (₹9.8 Cr)          | **−5**  | **+3** | **+5**   |

### Cash & Runway — `cm_budget` (Nimbus additional budget)

| # | Option                                              | Δ runway | Δ product |
|---|-----------------------------------------------------|--------:|---------:|
| 0 | Zero additional                                     | +2      | −2       |
| 1 | Up to ₹5 Cr                                         | −1      | +2       |
| 2 | Up to ₹10 Cr                                        | −3      | +3       |
| 3 | Up to ₹20 Cr (reserve draw)                         | **−6**  | **+5**   |

### Commercial Response — `cr_drift`

| # | Option                                              | Δ revenue | Δ margin | Δ runway | Δ share |
|---|-----------------------------------------------------|---------:|--------:|--------:|-------:|
| 0 | Hold price/positioning                              |          |         |         |        |
| 1 | Drift SE accessories bundle                         | +2       | +1      |         |        |
| 2 | Reduce Drift price −₹5K                             |          | −3      |         | +2     |
| 3 | Push Drift to Tier 2 cities                         | +1       |         | −1      | +1     |
| 4 | Wind down Drift marketing                           |          |         | +1      | −2     |

### Commercial Response — `cr_dealer`

| # | Option                                              | Δ revenue | Δ margin | Δ runway | Δ share | Δ team |
|---|-----------------------------------------------------|---------:|--------:|--------:|-------:|------:|
| 0 | No change                                           |          |         |         |        |       |
| 1 | Sell-through incentives                             | +2       | −1      |         | +1     |       |
| 2 | Brief select dealers on Nimbus (NDA)                |          |         |         | +1     | +1    |
| 3 | Pause new dealer onboarding                         |          |         | +1      | −1     |       |

### People & Stability — `ps_ret`

| # | Option                                              | Δ runway | Δ product | Δ team |
|---|-----------------------------------------------------|--------:|---------:|------:|
| 0 | No intervention                                     |         |          | −2    |
| 1 | Direction brief to engineering                      |         | +1       | +2    |
| 2 | ESOP acceleration                                   | −1      |          | +3    |
| 3 | Direction brief + ESOP                              | −1      | +1       | **+5**|
| 4 | Hire 4–6 new engineers                              | −2      | −1       | +2    |

---

## Table 3 — ShopPulse (Demo): decision impacts

### Growth Strategy — `gr_pace` (order volume growth target)

| # | Option                                              | Δ revenue | Δ margin | Δ runway | Δ share |
|---|-----------------------------------------------------|---------:|--------:|--------:|-------:|
| 0 | Hold flat — protect economics                       | −1       | +2      | +1      |        |
| 1 | Grow 15% — measured                                 | +2       |         |         |        |
| 2 | Grow 30% — aggressive                               | +5       | −3      | −2      | +3     |
| 3 | Grow 50%+ — growth at all costs                     | **+8**   | **−6**  | **−4**  | **+5** |

### Unit Economics — `ue_delivery` (delivery fee strategy)

| # | Option                                              | Δ revenue | Δ margin | Δ share |
|---|-----------------------------------------------------|---------:|--------:|-------:|
| 0 | Hold at ₹30                                         |          |         |        |
| 1 | Raise to ₹45                                        | −2       | +3      | −2     |
| 2 | Surge pricing (₹20–60)                              | +1       | +2      |        |
| 3 | Free for Plus subscribers only                      | +1       | +1      | +1     |

### Product & Category — `pr_focus`

| # | Option                                              | Δ revenue | Δ margin | Δ share | Δ product |
|---|-----------------------------------------------------|---------:|--------:|-------:|---------:|
| 0 | Stay core grocery                                   |          | +1      |        | +2       |
| 1 | Add electronics                                     | +2       | +2      |        | −2       |
| 2 | Add pharmacy                                        | +3       | +1      |        | −1       |
| 3 | Add everything                                      | +4       | −3      | +2     | −3       |

### Product & Category — `pr_plus` (Plus subscriber push)

| # | Option                                              | Δ revenue | Δ margin | Δ share |
|---|-----------------------------------------------------|---------:|--------:|-------:|
| 0 | Organic                                             |          |         |        |
| 1 | 3-month trial for ₹49                               | +2       |         | +1     |
| 2 | Bundle Plus with referral                           | +3       | −1      | +2     |
| 3 | Mandatory Plus for free delivery                    | +4       | +2      | −3     |

### Operations — `op_riders`

| # | Option                                              | Δ margin | Δ product | Δ team |
|---|-----------------------------------------------------|--------:|---------:|------:|
| 0 | Pure gig                                            | +1      | −2       |       |
| 1 | Hybrid                                              |         | +2       |       |
| 2 | Full-time in high-density only                      | −1      | +3       |       |
| 3 | 3PL for all delivery                                | −2      | −1       | −1    |

---

## Table 4 — VOLTA: curveball impacts

| Round | Curveball                          | Headline impact (uniform)             | Modifier (per team)                                                  | Pedagogy |
|------:|------------------------------------|---------------------------------------|----------------------------------------------------------------------|----------|
| Q2    | LFP Cell Price Spike               | margin −3, runway −1                  | `sc_battery` opt 1 → ×0.5; opt 2 (full hedge) → ×0.1                 | Hedging works |
| Q3    | Zephyr Launches at ₹76,000         | share −2, revenue −1                  | `com_go` opt 2/3 (expand or cut price) → ×0.4                        | Active defense matters |
| Q3    | VoltaOS 3-Star Safety Rating       | product −3, share −1                  | `eng_priority` opt 0 (BLE fix) → ×0.0 (fully protected)              | Quality discipline pays |
| Q4    | FAME III Subsidy Restructure       | revenue −2                            | `com_go` opt 1 (reduced Go) → ×0.3                                   | Reading regulatory signals |
| Q4    | Pune Plant Work Stoppage           | revenue −3, margin −1                 | `mfg_hosur` opt 3 (Pune-only) → ×1.5 (more exposed)                  | Concentration risk |
| Q5    | Strategic Acquisition Approach     | team +2                               | `sc_chipaxis` opt 2 (in-house SoC) → ×2.0                            | Long-horizon IP plays |

---

## Table 5 — ARC: curveball impacts

| Round | Curveball                              | Headline impact (uniform)        | Modifier (per team)                                          | Pedagogy |
|------:|----------------------------------------|----------------------------------|-------------------------------------------------------------|----------|
| Q1    | Zep Aire Launches (Full Spec Confirmed) | share −3, revenue −2             | `pd_path` opt 2/3 (already adapting) → ×0.4                  | Read the market early |
| Q2    | Maharashtra EV Subsidy                  | revenue +2, share +1             | none — uniform tailwind                                      | Macro tailwinds lift all |
| Q3    | SwiftEV — 400 new swap kiosks           | share −2                         | `fp_top` opt 4 (removable battery) → ×0.2                    | Infrastructure choice matters |
| Q3    | ARC Drift Wins Design Award             | product +1                       | none — narrative win                                         | Recognition ≠ commerce |
| Q4    | NovaBike Nova S2 Announced              | share −2                         | `pd_path` opt 2/3 (adapting) → ×0.5                          | Adaptation buys position |
| Q5    | FAME IV Swap Policy Signal              | share −1                         | `fp_top` opt 4 (removable battery) → ×0.0                    | Bet on the signal |

---

## Table 6 — ShopPulse (Demo): curveball impacts

| Round | Curveball                          | Headline impact (uniform)        | Modifier (per team)                                              | Pedagogy |
|------:|------------------------------------|----------------------------------|-----------------------------------------------------------------|----------|
| Q1    | Swiggy Instamart Price Drop        | share −2, margin −1              | `ue_delivery` opt 0 (hold ₹30) or opt 3 (Plus-only free) → ×0.4 | Pricing discipline |
| Q2    | Rider Strike Risk                  | product −2, margin −1            | `op_riders` opt 1 (hybrid) or opt 2 (full-time) → ×0.3          | Workforce model matters |
| Q3    | Dark Store Regulation Draft        | revenue −2, runway −1            | none — regulatory cost is uniform                                | Compliance is unavoidable |
| Q4    | Series A Term Sheet                | runway +5                        | `gr_pace` opt 0/1 (disciplined growth) → ×1.4                    | Discipline attracts capital |

**How modifiers stack:** if multiple modifiers match a team's choices for the same curveball, they multiply. If none match, the headline (uniform) impact applies in full.

---

## Table 7 — Round score formula

Score is computed from the team's **absolute** metrics at the end of the round, normalised to 0–100. It rewards teams whose overall state is strong, not just whose deltas were big this quarter.

```
norm(x, lo, hi) = clamp((x − lo) / (hi − lo) × 100, 0, 100)

score = round(
  0.25 × norm(revenue,        0, 30)  +
  0.20 × norm(grossMargin,  −20, 30)  +
  0.15 × norm(cashRunway,     0, 30)  +
  0.15 × norm(marketShare,    0, 100) +
  0.15 × norm(productHealth,  0, 100) +
  0.10 × norm(teamCapability, 0, 100)
)
```

Weighting reflects the pedagogical priorities baked into the cases:
- Revenue + margin together = 45% (commercial discipline is primary)
- Runway = 15% (cash management)
- Share + product = 30% (positioning + quality)
- Team capability = 10% (durable capability)

To shift the emphasis of a cohort (e.g. cash-focused), edit the weights in `_scoringNormaliseScore`.

---

## Invariants the engine guarantees

1. **Determinism.** Same starting metrics + same decisions + same curveballs ⇒ identical outcome. No randomness anywhere.
2. **Decision symmetry.** Same option in the same field of the same case ⇒ same decision-level delta for every team, every round.
3. **Curveball headline is uniform.** Every team takes the same headline delta. Only modifiers (which look at the team's own decisions) vary the effective impact per team.
4. **Carry-over.** Round N's outcome metrics become Round N+1's starting metrics. The case-default metrics (table at the top) are used only when no prior outcome exists (i.e. Round 1).
5. **Clamping.** After all deltas, metrics are clamped: revenue and cashRunway floor at 0, marketShare / productHealth / teamCapability clamped to [0, 100].
