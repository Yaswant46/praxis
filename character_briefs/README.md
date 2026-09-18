# Borrowed People — Character briefs (v1)

One sealed PDF per character, in the Praxis theme, generated from the same facts the
engine runs on. **Six briefs:** Arjun, Neha, Raghav, Farida, Devika, and the Sponsor
(the facilitator's operator brief).

```
character_briefs/
  build_briefs.py   # all content + renderer; the only file to edit
  html/<key>.html   # intermediate, Praxis-themed pages
  pdf/Praxis-BorrowedPeople-Brief-<Name>.pdf
```

## Rebuild

```
python3 character_briefs/build_briefs.py
```

Needs Google Chrome at `/Applications/Google Chrome.app` (headless print-to-PDF).
Without it the script writes the HTML only.

## What each brief contains

- **Who you are** — persona written against the character's real position on the
  demand map (e.g. Neha is needed 9 times, sent for 2; Raghav has no Q4 demand).
- **Year at a glance** — posture, slots, genuine need per quarter.
- **What you actually care about** — the character's anchors for *knew what I cared about*.
- **How to play it** — do / don't.
- **How the engine uses you** — selection = credit, ratings feed bands, drift check, recovery.
- **The year, quarter by quarter** — posture card + sample line, the sealed demand
  (primary / secondary + business why), who the Sponsor's directives will send
  (aligned / tension / unprompted / probably-not / recovery path), the trap.
- **Capacity and the squeeze** — slots vs genuine need vs likely asks.
- **How you rate** — the fixed 3×(1–3) rubric with per-character 3 / 2 / 1 anchors.
- **Q4 judgement** and **Sealed rules**.

The Sponsor brief instead carries the full 20-directive schedule with alignment
flags and ideals, the Voice lever + leadership-cell table, the curveball map, the
between-round debrief card, and Sponsor-specific sealed rules.

## Sources of truth

- `supabase/borrowed_schema.sql` — `bp_create_session` (demand map, capacities,
  directives, escalation cards, curveballs), `bp_adjusted_ideal` (recovery),
  `bp_leadership_cell`.
- `MANDATE_DIRECTIVES_v1.md` — alignment flags, tension targets, curveball map.
- `FACILITATOR_DEBRIEF_CARD.md` — the five beats.
- `borrowed.html` — rubric text, theme tokens.

Briefs cover the **full** variant (5 characters + Sponsor). The short variant
(Arjun, Neha, Farida + Sponsor) uses a different demand map and is not covered here.

## Design note — the briefs contain the hidden demand map

Each character brief tells its player who *genuinely* needs them each quarter,
marked <kbd>sealed</kbd>. This is deliberate: a character who knows the truth can
play the flattering wrong ask honestly (be tempted, then refuse in character)
instead of guessing. The trade-off is leak risk, which the "Sealed rules" section
addresses. If a cohort needs blind characters, strip the "Who the work actually
needs from you" block in `render_character`.
