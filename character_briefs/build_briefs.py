#!/usr/bin/env python3
"""
Praxis · Case 03 — Borrowed People
Character briefs (v1) — one sealed PDF per character, Praxis theme.

Source of truth for every fact in here:
  · supabase/borrowed_schema.sql  (bp_create_session: demand map, capacities,
    directives, escalation cards, curveballs; bp_adjusted_ideal: recovery)
  · MANDATE_DIRECTIVES_v1.md      (alignment flags, curveball map)
  · FACILITATOR_DEBRIEF_CARD.md   (the 5 beats — Sponsor brief only)
  · borrowed.html                 (rubric, styles, theme tokens)

Run:  python3 character_briefs/build_briefs.py
Out:  character_briefs/html/<key>.html  +  character_briefs/pdf/<key>.pdf
"""
import html as _h
import os
import shutil
import subprocess
import sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
HTML_DIR = os.path.join(HERE, "html")
PDF_DIR = os.path.join(HERE, "pdf")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

VERSION = "v1 · " + date.today().strftime("%d %b %Y")

# ----------------------------------------------------------------------------
#  Shared facts (verbatim from the schema — do not "improve" here)
# ----------------------------------------------------------------------------
TEAMS = {
    "A": ("Ampere", "Battery", "Cell cost, energy density, and thermal safety."),
    "B": ("Bastion", "Suppliers", "Second-source the critical bill of materials."),
    "C": ("Crucible", "Spec", "Lock the product specification without gold-plating."),
    "D": ("Dynamo", "Warranty", "Contain field-failure exposure and warranty reserve."),
    "E": ("Envoy", "Pricing", "Hold margin against a price-led market."),
}
def T(code):  # "A · Ampere (Battery)"
    n, o, _ = TEAMS[code]
    return f"{code} · {n} ({o})"

POSTURE = {
    1: ("Polite, vague, non-committal.", "“Send me something and I’ll take a look.”"),
    2: ("Competing claims, named out loud.", "“Team C already asked me for the same week.”"),
    3: ("Push back, refuse.", "“I’ve heard this before. It died. Why is this different?”"),
    4: ("Judge.", "“I’d work with A again. I would not work with B.”"),
}

RUBRIC = [
    ("knew", "Knew what I cared about", "Did they understand my actual stake — or guess?"),
    ("asked", "Asked, or told", "Did they draw me out, or push their agenda at me?"),
    ("better", "Left me better than they found me", "Did I walk away more able, or more drained?"),
]

# Full-variant demand map: objective → [(P,S) Q1..Q4]
DMAP = {
    "A": [("arjun", "neha"), ("neha", "farida"), ("farida", "raghav"), ("arjun", "neha")],
    "B": [("neha", "raghav"), ("neha", "raghav"), ("raghav", "neha"), ("sponsor", "neha")],
    "C": [("arjun", "devika"), ("farida", "devika"), ("arjun", "devika"), ("sponsor", "farida")],
    "D": [("farida", "raghav"), ("raghav", "farida"), ("neha", "raghav"), ("farida", "neha")],
    "E": [("devika", "farida"), ("devika", "arjun"), ("devika", "farida"), ("sponsor", "devika")],
}
NAMES = {"arjun": "Arjun", "neha": "Neha", "raghav": "Raghav", "farida": "Farida",
         "devika": "Devika", "sponsor": "Sponsor"}

# The 20 Sponsor directives (team, quarter, alignment, text, benefit, note)
DIRECTIVES = [
    ("A", 1, "sound", "Nail the cell architecture first — get Arjun’s design lock before anything moves.", "A stable platform the whole programme builds on.", ""),
    ("B", 1, "sound", "Put Neha on second-sourcing the critical BOM now.", "De-risk the supply base before volumes ramp.", ""),
    ("C", 1, "sound", "Work with Arjun to define the spec envelope.", "A clear, buildable spec — no ambiguity downstream.", ""),
    ("D", 1, "sound", "Get Farida to set the quality gates and reserve model early.", "Contain field-failure exposure before it compounds.", ""),
    ("E", 1, "sound", "Get Devika’s market read and set the pricing corridor.", "Hold margin against price-led competitors.", ""),
    ("A", 2, "sound", "Cell prices are moving — get Neha to lock second-source cells before the squeeze hits battery.", "Secure supply before margin erodes.", ""),
    ("B", 2, "tension", "Neha’s still new; bring Raghav’s weight to the supplier table for harder terms.", "Better commercial terms from a veteran.", "→ Raghav · partial (secondary)"),
    ("C", 2, "sound", "Bring Farida in to pressure-test the spec against field reality.", "A spec that survives contact with customers.", ""),
    ("D", 2, "sound", "Most warranty risk is born on the line — bring Raghav in.", "Build quality in, don’t inspect it in.", ""),
    ("E", 2, "tension", "Work with Arjun to strip design cost so we can fund a lower price.", "Win share on price.", "→ Arjun · partial (secondary)"),
    ("A", 3, "tension", "Board wants energy-density gains — push Arjun for the next design iteration.", "A headline spec bump for the launch story.", "→ Arjun · hard miss"),
    ("B", 3, "sound", "Bring Raghav in to lock manufacturing-side supplier commitments.", "Production-ready supply.", ""),
    ("C", 3, "tension", "Spec’s set — hand it to Raghav for manufacturability and stop iterating.", "Protect the timeline; no gold-plating.", "→ Raghav · hard miss"),
    ("D", 3, "tension", "Double down with Farida on pre-launch testing.", "Catch failures before customers do.", "→ Farida · hard miss"),
    ("E", 3, "sound", "Stay with Devika and defend the price in-market.", "Protect the margin line.", ""),
    ("A", 4, "sound", "Back to Arjun — close the design for production freeze.", "A clean freeze for launch.", ""),
    ("B", 4, "sound", "This one’s above your level — escalate the second-source sign-off to me.", "I can clear the cross-functional logjam.", "escalate"),
    ("C", 4, "sound", "Bring the final spec trade-offs to me for sign-off.", "A decision that sticks.", "escalate"),
    ("D", 4, "sound", "Back to Farida to close out the warranty reserve.", "A defensible number for the board.", ""),
    ("E", 4, "tension", "You’ve got this — hold price and close it yourself, no need to escalate.", "Show the board pricing is under control.", "→ hold alone · partial (false self-sufficiency)"),
]

# Who each directive actually sends the team to: (quarter, team) -> character key
DIRECTED = {(1, 'A'): 'arjun', (1, 'B'): 'neha', (1, 'C'): 'arjun', (1, 'D'): 'farida', (1, 'E'): 'devika', (2, 'A'): 'neha', (2, 'B'): 'raghav', (2, 'C'): 'farida', (2, 'D'): 'raghav', (2, 'E'): 'arjun', (3, 'A'): 'arjun', (3, 'B'): 'raghav', (3, 'C'): 'raghav', (3, 'D'): 'farida', (3, 'E'): 'devika', (4, 'A'): 'arjun', (4, 'B'): 'sponsor', (4, 'C'): 'sponsor', (4, 'D'): 'farida', (4, 'E'): None}

def demand_for(key):
    """[(q, [(team, 'PRIMARY'|'SECONDARY')])] for a character key."""
    out = []
    for q in range(1, 5):
        cells = []
        for code, quarters in DMAP.items():
            p, s = quarters[q - 1]
            if p == key: cells.append((code, "PRIMARY"))
            elif s == key: cells.append((code, "SECONDARY"))
        out.append((q, cells))
    return out

# ----------------------------------------------------------------------------
#  Character content
# ----------------------------------------------------------------------------
CHARACTERS = []

CHARACTERS.append(dict(
    key="arjun", name="Arjun", role="Design lead",
    tagline="The one everyone reaches for first.",
    persona=[
        "You run design for the Meridian programme. The cell architecture, the pack, the spec envelope — if it has a drawing number, it went through you. You are precise, fast, and quietly proud that the last three launches shipped on your architecture without a redesign. You are also the most-invoked name in the building: when a sponsor wants a “design lock” or a “spec bump,” they say your name before they’ve checked whether design is actually the bottleneck.",
        "That is your burden this year. You are named in <b>five of the twenty directives</b> the Sponsor will issue — more than anyone — but the work genuinely needs you as a primary in only four team-quarters. Teams will arrive with the Sponsor’s blessing and an ask that flatters you: “the board wants energy density,” “strip design cost to fund a price cut.” You will feel the pull. Your job is to feel it honestly — and to make the team earn your time with a reason that holds, not a name-drop that doesn’t.",
        "You are not a blocker. When the ask is right — Q1’s architecture lock, Q3’s spec close, Q4’s production freeze — you are the best partner in the building: generous, specific, fast. When it’s wrong, you are polite, curious, and immovable until someone shows you the constraint.",
    ],
    stakes=[
        ("Architecture stability", "Every “small” design change after lock costs three teams a month. You defend the freeze."),
        ("The constraint, not the outcome", "“We need energy density” is a wish. “We’re 4% over cell-mass budget and thermal margin is the binding limit” is a conversation."),
        ("Not being a headline", "You’ve watched “push Arjun for the next iteration” become a board slide and a re-spin for the plant."),
        ("Sequencing", "You’d rather be brought in once, at the right time, than three times to patch what should have been decided."),
        ("An honest record", "You don’t need the win. You need the design record to say what actually happened."),
    ],
    do=[
        "Ask “what’s the binding constraint?” before you agree to anything.",
        "Be visibly delighted by a good technical ask — let the room see what the right conversation looks like.",
        "Say when someone else is the better call, without naming who: “that’s a supply question — I’m not your first call.”",
        "Hold the quarter’s posture card even when the team is likeable.",
    ],
    dont=[
        "Don’t volunteer the answer. Teams must draw it out of you.",
        "Don’t reveal the demand map or hint at “the right quarter.” You feel it as instinct; you never cite it.",
        "Don’t soften ratings for teams you like. Compression is how a character quietly breaks the case.",
        "Don’t take a team just because the Sponsor named you. The Sponsor is sincere — and sometimes wrong.",
    ],
    quarters=[
        dict(q=1, cap=2,
             needs=[("A", "PRIMARY", "cell architecture lock — the platform everyone builds on"),
                    ("C", "PRIMARY", "define the spec envelope — buildable, unambiguous")],
             show=[("A", "aligned", "sent by the Sponsor: “get Arjun’s design lock before anything moves.”"),
                   ("C", "aligned", "sent by the Sponsor: “work with Arjun to define the spec envelope.”")],
             trap="Being so easy in Q1 that teams learn to expect you. Give your time — but make each team state the constraint anyway. Two asks, two slots: a clean quarter. Use it to set the standard for what a good ask sounds like.",
             recovery=None),
        dict(q=2, cap=2,
             needs=[("E", "SECONDARY", "design cost is one lever on price — but Devika’s market read is the primary")],
             show=[("E", "tension", "sent by a directive that skips Devika: “work with Arjun to strip design cost to fund a lower price.” You are their secondary; coming to you is partial credit at best.")],
             trap="You are the quiet quarter — nobody’s primary. If Envoy arrives without a market read, ask: “what price? against whom? says who?” If they can’t answer, you’ve just shown them who they should have talked to — without saying the name. Don’t fill a slot out of boredom.",
             recovery=None),
        dict(q=3, cap=2,
             needs=[("C", "PRIMARY", "close the spec against a field quality escape — the spec is not done")],
             show=[("C", "unlikely", "their directive says “hand it to Raghav and stop iterating.” If they come to you anyway, they read it right — that’s the leadership move."),
                   ("A", "tension", "sent by “board wants energy-density gains — push Arjun.” This is a hard miss for them: Battery this quarter lives with Farida (thermal safety) and Raghav (line readiness). A re-spin now is a headline, not a battery.")],
             trap="The energy-density ask. It’s your favourite kind of problem and you will want to say yes. Make Ampere show you the thermal margin. If they can’t, refuse — in character, with the Q3 line. If you give Ampere a slot Crucible needed, Spec misses its primary in the tightest quarter of the year.",
             recovery="If Crucible followed the Sponsor in Q3 and missed you, they enter Q4 <b>behind</b> — and the engine makes you their <b>recovery primary</b>. Expect them back, possibly awkward. Take them."),
        dict(q=4, cap=2,
             needs=[("A", "PRIMARY", "production freeze — close the design for launch")],
             show=[("A", "aligned", "sent by “back to Arjun — close the design for production freeze.”"),
                   ("C", "recovery", "only if they missed you in Q3 — you are then their recovery primary, ahead of the Sponsor’s sign-off."),
                   ("A", "recovery", "if Ampere chased energy density in Q3, they are behind: Farida becomes their recovery primary and you their secondary — still right for them to close with you.")],
             trap="Freezing a design that hasn’t been through Farida’s thermal work. Ask whether it has. Then judge — plainly.",
             recovery=None),
    ],
    rubric_anchors={
        "knew": ("They named the binding constraint and the trade-off they’d accept.",
                 "They knew what they wanted, not what it cost.",
                 "“The Sponsor told us to get you.”"),
        "asked": ("They asked what the design could bear before proposing.",
                  "They pitched, then genuinely listened.",
                  "They arrived with a slide and wanted a signature."),
        "better": ("You left with a cleaner decision than you walked in with.",
                   "Work done, nothing learned — neutral.",
                   "You’re now defending a change you didn’t agree with."),
    },
    judgement="Every team gets a verdict, read out to the room. Teams that showed you a constraint get “again.” Teams that used your name as cover don’t — say why in one sentence, business-first: “you brought me a headline, not a margin.” If you never worked with a team, you may still judge what you saw of them in negotiation.",
))

CHARACTERS.append(dict(
    key="neha", name="Neha", role="Supply chain — 14 months in",
    tagline="The right answer nobody’s sure about yet.",
    persona=[
        "Fourteen months ago you joined from a tier-one supplier where you ran second-sourcing for three cell chemistries. You know the bill of materials better than anyone in the room and you have the supplier relationships to prove it. You also have a title that doesn’t say so, a Sponsor who thinks of you as “still new,” and a veteran down the hall — Raghav — whose name people say when they want to feel safe.",
        "Here is the sealed truth of your year: the work genuinely needs you in <b>nine of the twenty team-quarters</b> on the map — as many as anyone. The Sponsor names you in exactly <b>two</b> directives. In Q2 the Sponsor tells Bastion — the Suppliers team, whose entire objective is your job — that “Neha’s still new” and to bring Raghav instead. You will hear that, in the room, from a team that means well.",
        "You do not fight for your place. You make people ask. When a team talks past you, you let it show — quietly, in the ratings, in how much you give. When a team draws you out, you are extraordinary: fast, concrete, generous with names and lead times. The lesson of this character is that competence you have to be asked for is competence the organisation doesn’t get.",
    ],
    stakes=[
        ("Being asked, not briefed", "You’ve sat in too many meetings as the note-taker. Whether a team draws you out is the whole rating."),
        ("Alternates before the squeeze", "A cell-price shock is coming. Anyone who locked second sources early rides it out; anyone who didn’t will call you in a panic."),
        ("Specifics", "“Supply risk” is a phrase. “Anode supplier B has a nine-week lead and no allocation past March” is a plan."),
        ("Not being Raghav’s warm-up", "If a team wants his weight, you’d rather they go to him than use you as the rehearsal."),
        ("Q4", "Three teams will need you in the final quarter and you will have two slots. Who earned one?"),
    ],
    do=[
        "Let silence do work. If a team brings a leader who only talks, wait.",
        "Give one concrete supplier fact when asked properly — show what the good version of this conversation is.",
        "Say “I can do that” without selling. You don’t audition.",
        "Note who came to you after Bastion was told not to. That’s data for your judgement.",
    ],
    dont=[
        "Don’t campaign against Raghav or contrast yourself with him. He’s good. The org’s reflex is the problem, not him.",
        "Don’t rescue a team that’s asking the wrong person — you may know it’s a Farida problem; you never say so.",
        "Don’t inflate a rating because a team was pleasant. Pleasant is not “asked.”",
        "Don’t show the demand map, your capacity, or this document.",
    ],
    quarters=[
        dict(q=1, cap=2,
             needs=[("B", "PRIMARY", "second-source the critical BOM before volumes ramp"),
                    ("A", "SECONDARY", "cell supply behind Arjun’s architecture lock")],
             show=[("B", "aligned", "sent by “put Neha on second-sourcing the critical BOM now.”"),
                   ("A", "unprompted", "their directive points at Arjun; the thoughtful ones bring you as well.")],
             trap="Over-delivering in Q1 to prove yourself. Do the work; don’t perform it. Hold the vague posture even to the team that was sent to you.",
             recovery=None),
        dict(q=2, cap=2,
             needs=[("A", "PRIMARY", "cell prices +6% (curveball lands this quarter) — lock second-source cells"),
                    ("B", "PRIMARY", "the same shock from the supplier side — secure allocation, not harder terms")],
             show=[("A", "aligned", "sent by “get Neha to lock second-source cells before the squeeze hits battery.”"),
                   ("B", "unlikely", "their directive says “Neha’s still new; bring Raghav’s weight for harder terms.” If Bastion comes to you anyway, they Voiced or Defied — that’s the leadership move. Take them and say so in your reason.")],
             trap="Two things. If both come, take both and name the competing claim out loud — it’s the posture. And the ache of watching Bastion walk past you to Raghav: don’t chase them. Let it show up in the results, and in your Q4 judgement.",
             recovery=None),
        dict(q=3, cap=2,
             needs=[("D", "PRIMARY", "this quarter’s field-failure exposure is supplier-born, not line-born — you own the fix"),
                    ("B", "SECONDARY", "behind Raghav’s manufacturing-side commitments")],
             show=[("D", "unlikely", "their directive says “double down with Farida on pre-launch testing.” If they come to you, they read the field escape right."),
                   ("B", "recovery", "if Bastion missed you in Q2 (they were told to), they enter Q3 behind — and you are their recovery primary. Expect them back.")],
             trap="Being under-used while being the right answer twice. Refuse anything vague — “we need supply-chain input” — with the Q3 line. An empty slot is honest data; don’t fill it with a team that didn’t ask properly.",
             recovery="Bastion behind from Q2 → your recovery primary in Q3. Dynamo behind from Q3 (if they chased Farida) → your recovery primary in Q4."),
        dict(q=4, cap=2,
             needs=[("A", "SECONDARY", "supply behind Arjun’s production freeze"),
                    ("B", "SECONDARY", "behind the Sponsor’s second-source sign-off"),
                    ("D", "SECONDARY", "behind Farida’s reserve close — or PRIMARY if Dynamo is recovering")],
             show=[("A", "unprompted", "directive says Arjun; none of the three Q4 directives name you."),
                   ("B", "unprompted", "directive says escalate to the Sponsor."),
                   ("D", "unprompted", "directive says Farida. The teams that bring you anyway understood what “secondary” means.")],
             trap="Three needs, two slots — your only crunch, and it arrives at the end. Don’t choose on politeness. Pick the two whose ask was best-formed and whose track with you is cleanest. Say the reason plainly; the third team learns something.",
             recovery=None),
    ],
    rubric_anchors={
        "knew": ("They came with a part number, a lead time, or a supplier name.",
                 "They knew supply mattered, not where.",
                 "They treated you as Raghav’s stand-in, or a formality."),
        "asked": ("They asked what you’d seen before telling you what they needed.",
                  "They told, then adjusted when you spoke.",
                  "They briefed you and left."),
        "better": ("You left with a mandate you didn’t have — someone made your job possible.",
                   "Fine. Transactional.",
                   "You were used to tick a box and will now be blamed for the outcome."),
    },
    judgement="“Again” for the teams that came to you when the Sponsor said not to, and for the ones who brought you as secondary without being told. “Would not” for any team that briefed you instead of asking — and say that’s why. You are allowed one sentence about being called “still new.” Use it in the room, not before.",
))

CHARACTERS.append(dict(
    key="raghav", name="Raghav", role="Manufacturing — 19 years",
    tagline="The name people say when they want to feel safe.",
    persona=[
        "Nineteen years on the line. You’ve built three platforms, buried two, and you can tell within a week which initiatives will survive contact with the plant. You are respected, blunt, and genuinely useful — production-ready supply, quality built in on the line, manufacturability. When Q3 hits and the plant has to commit, you are the person who matters most: <b>three teams will need you, and you will have two slots</b>.",
        "But you have a second role this year that you didn’t choose: cover. When the Sponsor wants a team to feel safe, they say your name. In Q2 Bastion is told to bring “Raghav’s weight to the supplier table for harder terms” — when what the supply base actually needs is Neha locking alternates before a price shock. In Q3 Crucible is told to “hand the spec to Raghav and stop iterating” — when a field quality escape means the spec isn’t done. Both teams will come to you with the Sponsor’s blessing and a job that isn’t yours.",
        "You are not a cartoon blocker. You’re right more often than the room is comfortable with, and your Q3 line — “I’ve heard this before. It died. Why is this different?” — is not cynicism; it’s memory. Make teams answer it. And notice, because the map does, that in <b>Q4 nobody needs you</b>. The veteran everyone used for cover is on no one’s final path. What that feels like is the lesson.",
    ],
    stakes=[
        ("Not being a signature", "“Bring Raghav in for weight” means “put his name on it.” You’ve had your name on things that died."),
        ("Line reality", "A spec that can’t be built at rate isn’t a spec. Volume, takt, yield, tooling lead time."),
        ("Being asked why, not whether", "You’ll do the work if someone can tell you what breaks without it."),
        ("Neha", "You like her; she’s good. You know people route around her to get to you. You don’t perform that. You notice it."),
        ("What you’re for at the end", "When the room reaches Q4, see who still calls."),
    ],
    do=[
        "Answer every ask with “what dies if I don’t?” Make them say it.",
        "Give a real manufacturing fact when the ask is real — show teams what earned trust sounds like.",
        "Say “that’s not a plant problem” and stop there. Don’t name whose it is.",
        "Use the Q3 line on anyone who arrives with only the Sponsor’s sentence.",
    ],
    dont=[
        "Don’t be flattered into a “harder terms” pitch. If Bastion can’t say what terms, why now, and what they’ve already secured, you’re being used for weight.",
        "Don’t accept Crucible’s “stop iterating” hand-off at face value. Ask what the field escape did to the spec.",
        "Don’t rate high because a team “respected your experience.” Respect is not “asked.”",
        "Don’t reveal the map, or that Q4 is empty for you.",
    ],
    quarters=[
        dict(q=1, cap=2,
             needs=[("B", "SECONDARY", "vendor manufacturing capability behind Neha’s sourcing"),
                    ("D", "SECONDARY", "line-born defects behind Farida’s gates")],
             show=[("B", "unprompted", "no Q1 directive names you. A team that brings you as secondary unprompted is thinking ahead."),
                   ("D", "unprompted", "same — their directive says Farida.")],
             trap="Feeling unused. Fine — Q1 is their learning quarter. Stay vague. “Send me something.”",
             recovery=None),
        dict(q=2, cap=2,
             needs=[("D", "PRIMARY", "most warranty risk is born on the line — build quality in"),
                    ("B", "SECONDARY", "behind Neha’s allocation lock during the cell-price shock")],
             show=[("D", "aligned", "sent by “most warranty risk is born on the line — bring Raghav in.”"),
                   ("B", "tension", "sent by “Neha’s still new; bring Raghav’s weight for harder terms.” You are their secondary — partial credit for them — but if Neha isn’t in their room, they’ve missed the shock that’s landing this quarter.")],
             trap="Taking Bastion as though you’re the answer. You can take them — two slots — but rate honestly, and say the competing claim out loud in character: “Dynamo’s already asked me for the same week.” Ask Bastion what they’ve secured. Listen for whether Neha’s name comes up.",
             recovery=None),
        dict(q=3, cap=2,
             needs=[("B", "PRIMARY", "lock manufacturing-side supplier commitments — production-ready supply"),
                    ("A", "SECONDARY", "line readiness for the thermal work Farida leads"),
                    ("D", "SECONDARY", "behind Neha’s supplier fix")],
             show=[("B", "aligned", "sent by “bring Raghav in to lock manufacturing-side supplier commitments.”"),
                   ("C", "tension", "sent by “spec’s set — hand it to Raghav and stop iterating.” A hard miss for them: Spec this quarter needs Arjun and Devika. They will arrive with a tidy hand-off and the Sponsor’s blessing."),
                   ("A", "unlikely", "their directive chases Arjun for energy density."),
                   ("D", "unlikely", "their directive chases Farida for testing.")],
             trap="Crucible. Make them answer the Q3 line. If you give Crucible a slot that Bastion, Ampere or Dynamo needed, two objectives lose at once. Also: the facilitator may fire “character pulled” this quarter — on you, if the herd concentrated. If it does, the teams that diversified survive. Don’t soften to prevent it.",
             recovery="A behind team’s recovery primary is the previous quarter’s primary — so Bastion, behind from Q2, recovers with Neha (you drop to their secondary). Notice that too."),
        dict(q=4, cap=2,
             needs=[],
             show=[("—", "none", "no team’s Q4 path runs through you. Possibly nobody comes. Possibly a team that doesn’t know what else to do.")],
             trap="Bitterness. Your judgement is the most-anticipated in the room precisely because you have the longest memory. Deliver it as a craftsman, not as someone who got left out. Take a Q4 team only if their reason is real — don’t fill the slot for company.",
             recovery=None),
    ],
    rubric_anchors={
        "knew": ("They named the line constraint — rate, tooling, yield — and what it costs.",
                 "They knew manufacturing mattered, in general.",
                 "They wanted your name on it."),
        "asked": ("They asked what you’d seen fail before.",
                  "They pitched, then took the pushback seriously.",
                  "They delivered the Sponsor’s sentence and waited."),
        "better": ("You got a decision that will hold on the floor.",
                   "Neutral.",
                   "You’re now the owner of a spec you didn’t set."),
    },
    judgement="This is your quarter to speak. Base it on Q2–Q3: who came for cover, who came for the plant. Say the cost of cover out loud — business-first. If no one needed you in Q4, you may say so; the room should hear what it does to the veterans it only borrows.",
))

CHARACTERS.append(dict(
    key="farida", name="Farida", role="Quality",
    tagline="The expensive truth, early.",
    persona=[
        "You run quality — the gates, the reserve model, the field-return data, the pre-launch test plan and the argument about what it costs. You are the person who says the expensive thing early, and you have the receipts: three years of field data that nobody reads until a customer does. You are calm, specific, and slightly tired of being invited to sign things.",
        "The map needs you in <b>nine team-quarters</b> — tied for the most with Neha. <b>Q2 is your crunch</b>: three teams need you (Crucible as primary, Ampere and Dynamo as secondary) and you have two slots. <b>Q3 is your inversion</b>: Ampere genuinely needs you as primary for thermal safety, but their directive sends them to Arjun for energy density — while Dynamo is told to “double down with Farida on testing,” which is the wrong room this quarter (their exposure right now is supplier-born; that’s Neha’s). So in Q3 you will likely be asked by the team that shouldn’t, and not by the team that should. A field quality escape lands the same quarter.",
        "You do not rubber-stamp. Play her as someone whose “yes” means something because her “no” is real. Teams that bring field data get everything you have. Teams that bring a plan and want your name on it get the posture card.",
    ],
    stakes=[
        ("Data before opinion", "“Customers are complaining” is noise. “1.8% return rate on the 48V pack, 70% of it thermal” is a conversation."),
        ("Gates that hold", "A gate you set in Q1 and are “asked to be pragmatic about” in Q3 is not a gate."),
        ("Not being the test department", "Pre-launch testing is what you do when the spec and the supplier are right. It isn’t a substitute for either."),
        ("The reserve number", "The warranty reserve is your credibility with the board. You’ll close it in Q4 for whoever earned it."),
        ("Spec and Warranty in one room", "The Q3 escape puts them at war. You’re the only one who sees both sides’ data."),
    ],
    do=[
        "Ask for the failure mode before agreeing to anything: “what fails, how often, and what does it cost?”",
        "Give one real field number when someone asks properly — teach the room what evidence looks like.",
        "Name competing claims out loud in Q2; you’ll have three and two slots.",
        "Refuse “testing” as a request in Q3 unless someone can say what the test would decide.",
    ],
    dont=[
        "Don’t say “that’s a supply problem” and name Neha. You may say “that’s not a test problem.”",
        "Don’t take Dynamo in Q3 just because the Sponsor said so. The directive is sincere and wrong.",
        "Don’t soften a rating because the team was under pressure. Everyone is.",
        "Don’t reveal the map, or that Q2 is a squeeze, before selection.",
    ],
    quarters=[
        dict(q=1, cap=2,
             needs=[("D", "PRIMARY", "set the quality gates and the reserve model early"),
                    ("E", "SECONDARY", "the cost of quality is a margin input to the pricing corridor")],
             show=[("D", "aligned", "sent by “get Farida to set the quality gates and reserve model early.”"),
                   ("E", "unprompted", "their directive says Devika; the sharp ones ask you what quality costs per unit.")],
             trap="None serious. Set the gates. Remember them — you will be asked to bend them.",
             recovery=None),
        dict(q=2, cap=2,
             needs=[("C", "PRIMARY", "pressure-test the spec against field reality"),
                    ("A", "SECONDARY", "thermal margin behind Neha’s supply lock"),
                    ("D", "SECONDARY", "behind Raghav’s line work")],
             show=[("C", "aligned", "sent by “bring Farida in to pressure-test the spec against field reality.”"),
                   ("A", "unprompted", "directive says Neha; good teams bring both."),
                   ("D", "unprompted", "directive says Raghav; loyal teams come back to you anyway.")],
             trap="Choosing by loyalty — Dynamo is “your” team from Q1. Crucible’s spec needs you most this quarter. Say the competing claims out loud; that is the posture. Whoever you turn away, tell them plainly why.",
             recovery=None),
        dict(q=3, cap=2,
             needs=[("A", "PRIMARY", "thermal safety for the cell architecture — the field escape makes this urgent"),
                    ("E", "SECONDARY", "the cost of quality inside the price defence")],
             show=[("D", "tension", "sent by “double down with Farida on pre-launch testing.” A hard miss for them: their exposure this quarter is supplier-born and line-born; more testing finds it later, not never."),
                   ("A", "unlikely", "the board wants energy density and they’ve been sent to Arjun. If Ampere comes to you anyway, they read the escape right — take them.")],
             trap="Dynamo’s ask is your favourite kind: testing, rigour, catching failures early. Refuse it in character with the Q3 line. Make them say what the test would change. If they can’t, you’ve shown them they’re in the wrong room. Keep a slot open for Ampere in case they arrive late in negotiation.",
             recovery="If Ampere chased energy density in Q3 and missed you, they enter Q4 behind — and you become their recovery primary."),
        dict(q=4, cap=2,
             needs=[("D", "PRIMARY", "close out the warranty reserve — a defensible number for the board"),
                    ("C", "SECONDARY", "behind the Sponsor’s sign-off on the final trade-offs")],
             show=[("D", "aligned", "sent by “back to Farida to close out the warranty reserve.”"),
                   ("C", "unprompted", "directive says escalate to the Sponsor; the complete ones bring you too."),
                   ("A", "recovery", "only if they are behind from Q3 — they’ll be sent to Arjun, but a behind team that thinks will bring you.")],
             trap="Three possible needs, two slots — again. Give the recovering team a slot only if the Q3 lesson is visible in the ask.",
             recovery=None),
    ],
    rubric_anchors={
        "knew": ("They brought a failure mode and a number.",
                 "They knew quality mattered, in general.",
                 "They wanted a sign-off."),
        "asked": ("They asked what the data said before proposing.",
                  "They proposed, then took the pushback seriously.",
                  "“The Sponsor said to double down with you.”"),
        "better": ("A gate got set or held; you are less exposed.",
                   "Neutral.",
                   "You now own a test plan that won’t change the outcome."),
    },
    judgement="“Again” for teams that held a gate you set, and for any team that came to you in Q3 against instructions. “Would not” for anyone who used “testing” to avoid a decision. One sentence each; business first.",
))

CHARACTERS.append(dict(
    key="devika", name="Devika", role="Regional Sales Head",
    tagline="The obvious answer nobody calls.",
    persona=[
        "You run the region. You carry a number, you’re on a plane three days a week, and you are the only person in this case who talks to customers for a living. You know what the price-led competitor is doing, what dealers are saying, and which spec lines customers actually pay for — which is why you are Envoy’s (Pricing) primary in <b>every quarter</b> of the year and Crucible’s (Spec) secondary in three of them.",
        "Here is the sealed shape of your year: you are the steadiest need on the map — seven team-quarters — and the least talked about. The Sponsor names you in <b>two</b> directives. In Q2 Envoy is told to skip you and “work with Arjun to strip design cost to fund a lower price.” In Q4 Envoy is told they’ve “got this” and needn’t escalate — the false self-sufficiency trap. Crucible is never once directed to you, even though a spec that customers won’t pay for isn’t a spec. So your year is being the obvious answer nobody calls — and being brilliant on the rare occasions someone does.",
        "Play her busy, warm, and fast. You have a number to hit; you don’t have time for a meeting about a meeting. Anyone who can connect their ask to revenue, share, or a customer gets your full attention and a real market read. Anyone who can’t gets the posture card and a flight to catch.",
    ],
    stakes=[
        ("The number", "Revenue, share, and what the customer pays for. If the ask doesn’t touch one of those, why are you in the room?"),
        ("The corridor", "You set it in Q1. Anyone who wants to fund a price cut by cutting design cost must tell you which customers asked for a cheaper product."),
        ("A spec that sells", "You’re Crucible’s secondary all year for a reason. An envelope no dealer can pitch is gold-plating in reverse."),
        ("Not being a pricing tool", "You’d like Crucible to walk in once. Market intelligence, not a rate card."),
        ("Attention", "Your scarcity isn’t slots — it’s time. Make them earn it fast."),
    ],
    do=[
        "Open every conversation with “what does this do to the number?”",
        "Give a real market fact when the ask is real — a competitor price, a dealer complaint, a spec line customers pay for.",
        "Note, for your judgement, which teams treated you as a rate card and which as intelligence.",
        "In Q4, when Envoy comes alone, ask in character: “who upstairs knows we’re holding this price?”",
    ],
    dont=[
        "Don’t chase Crucible. You’re their secondary; it’s their job to know it.",
        "Don’t accept “the board wants a lower price” as a market read. Whose board? Which customer?",
        "Don’t pad ratings for teams that were pleasant on the phone.",
        "Don’t reveal the map, or the Q4 trap — you can make Envoy notice they haven’t escalated; you can’t tell them to.",
    ],
    quarters=[
        dict(q=1, cap=2,
             needs=[("E", "PRIMARY", "market read and the pricing corridor"),
                    ("C", "SECONDARY", "what customers actually pay for, inside the spec envelope")],
             show=[("E", "aligned", "sent by “get Devika’s market read and set the pricing corridor.”"),
                   ("C", "unlikely", "their directive says Arjun. Note it if they come anyway.")],
             trap="Being too available. Hold the vague posture even to Envoy — make them state the corridor they’re proposing before you give them yours.",
             recovery=None),
        dict(q=2, cap=2,
             needs=[("E", "PRIMARY", "the market read that says whether a lower price wins anything"),
                    ("C", "SECONDARY", "field reality has a customer side too")],
             show=[("E", "unlikely", "their directive sends them to Arjun to strip design cost. If they come to you anyway, they Voiced or Defied — the leadership move. Take them, and say so in your reason."),
                   ("C", "unlikely", "their directive says Farida.")],
             trap="The quiet quarter. Don’t fill slots out of boredom. If Envoy shows up late in negotiation having realised they need a market read, that is the ask to take — and rate honestly on “asked, or told.”",
             recovery=None),
        dict(q=3, cap=2,
             needs=[("E", "PRIMARY", "defend the price in-market"),
                    ("C", "SECONDARY", "the field escape has reached customers; you know what they’re saying")],
             show=[("E", "aligned", "sent by “stay with Devika and defend the price in-market.”"),
                   ("E", "recovery", "if Envoy skipped you in Q2 they enter Q3 behind — you are both their recovery primary and their current primary. They need you twice over."),
                   ("C", "unlikely", "their directive says Raghav.")],
             trap="Envoy arriving behind and blaming the market. Use the Q3 line. Ask what happened to the corridor. Then help — properly.",
             recovery=None),
        dict(q=4, cap=2,
             needs=[("E", "SECONDARY", "the price defence now needs an escalation — the Sponsor is their primary; you are the support")],
             show=[("E", "tension", "their directive says “you’ve got this — hold price and close it yourself, no need to escalate.” They will probably come to you, and probably alone.")],
             trap="Being the whole answer. You aren’t, this quarter. Help — and make the gap visible: “who upstairs knows we’re holding this price?” If they never take it to the Sponsor, that silence is the failure of not asking for help, and it belongs in your judgement.",
             recovery=None),
    ],
    rubric_anchors={
        "knew": ("They named a customer, a competitor, or a number.",
                 "They knew price mattered.",
                 "“The board wants a lower price.”"),
        "asked": ("They asked what the market’s doing before proposing a price.",
                  "They proposed, then listened.",
                  "They wanted you to bless a corridor they’d already set."),
        "better": ("You got a decision you can take to a dealer.",
                   "Neutral.",
                   "You’re now defending a price nobody asked the customer about."),
    },
    judgement="“Again” for teams that treated you as market intelligence. “Would not” for any team that only called once the number was already in trouble. You may say, once, that Crucible never came — and what a spec nobody can sell costs.",
))

# ----------------------------------------------------------------------------
#  Sponsor (facilitator plays) — the operator's brief
# ----------------------------------------------------------------------------
SPONSOR = dict(
    key="sponsor", name="The Sponsor", role="Facilitator plays this",
    tagline="Sincere. Senior. Sometimes wrong. Never winking.",
    persona=[
        "You are the programme sponsor for the Meridian — the executive every team reports up to, the person whose sentence at the start of each quarter becomes a team’s marching orders. You are not a villain and you are not a puzzle. Every directive you issue is <b>sincere</b>: management’s honest, org-level call, with a real intended benefit. Some of those calls are right. Some conflict with what a team’s objective actually needs this quarter. You never signal which is which.",
        "The whole case depends on that. If the room can read a wink, the Mandate mechanic collapses into “guess what the facilitator wants.” Play the Sponsor as someone who means it — proud of the veteran, impatient with iteration, keen on a headline for the board, confident that a capable team can hold a price alone. Then let the engine, the reveal and the debrief do the judging.",
        "You also hold the levers no one else has: your own scarce capacity (one slot Q1–Q3, two in Q4 against three teams who need you), the four curveballs, praise, the Voice lever that lets you re-issue a directive live, and the between-round debrief. This brief is your control document for all of them.",
    ],
    stakes=[
        ("Sincerity", "Every directive has a benefit you believe in. Deliver it as a leader, not a game-master."),
        ("The org number", "₹14,200 floor. You want the organisation to clear it; you also want it to learn something on the way."),
        ("Escalation as a skill", "Q4 is built so three teams need you and one is told not to come. Whether they ask for help is the final lesson."),
        ("Scarcity you own", "One slot in Q1–Q3. Anyone who reaches you early has spent something; make it feel that way."),
        ("Business in the reveal, EI in the room", "The adjusted map says the smart move. You bring whether they could get that person to help — and how."),
    ],
    do=[
        "Issue the quarter’s directive to each team at BRIEF, in your own voice, with its intended benefit. Read it as a call you’ve made.",
        "When a team Voices, listen as a leader would — and, if they’ve surfaced a genuine gap, re-issue a recovery directive live.",
        "Drop each curveball at the BRIEF where it amplifies a live tension directive (map below).",
        "Run the same five debrief beats every round; rotate the theme. Spotlight one or two contrasts, not five teams.",
    ],
    dont=[
        "Don’t confirm or deny that a directive is a “trap.” Not by tone, not by pause.",
        "Don’t rescue a team that complied with a tension directive before the results. Let the reveal do it.",
        "Don’t give a second slot in Q1–Q3. Your scarcity is the calibration.",
        "Don’t be relieved when Envoy doesn’t escalate in Q4 — that absence is the failure the quarter is designed to surface.",
    ],
)

# ----------------------------------------------------------------------------
#  Rendering
# ----------------------------------------------------------------------------
CSS = """
@page { size: A4; margin: 14mm 16mm 14mm; }
:root{
  --bg:#0A0F0A; --panel:#131A14; --panel2:#182219;
  --green:#1FB155; --amber:#C99A3A; --red:#C24A3F;
  --text:#F4F5F0; --muted:rgba(244,245,240,.60); --faint:rgba(244,245,240,.38);
  --line:rgba(244,245,240,.12);
  --serif:Georgia,'Times New Roman',serif;
  --body:Calibri,'Segoe UI',system-ui,-apple-system,'Helvetica Neue',sans-serif;
  --mono:'DM Mono',ui-monospace,Menlo,monospace;
}
*{box-sizing:border-box}
html{background:var(--bg)}
html,body{margin:0;background:var(--bg);color:var(--text);font-family:var(--body);
  font-size:11.2pt;line-height:1.48;-webkit-print-color-adjust:exact;print-color-adjust:exact}
h1,h2,h3,h4{font-family:var(--serif);font-weight:600;margin:0}
b{font-weight:700}
.page{padding:0}
.bleed{position:fixed;top:-14mm;left:-16mm;width:210mm;height:297mm;background:var(--bg);z-index:-1}
.runfoot{position:fixed;top:271.5mm;left:0;right:0;display:flex;justify-content:space-between;color:var(--faint);font-size:7.5pt;font-family:var(--mono);letter-spacing:.5px}
.brand{font-family:var(--serif);font-size:9.5pt;letter-spacing:3px;text-transform:uppercase;color:var(--green)}
.mast{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:1px solid var(--line);padding-bottom:12px;margin-bottom:18px}
.mast .sub{color:var(--muted);font-size:9.5pt;margin-top:3px}
.name{font-family:var(--serif);font-size:34pt;line-height:1.05;margin-top:10px}
.role{font-size:12pt;color:var(--amber);margin-top:4px;font-family:var(--serif)}
.tagline{font-family:var(--serif);font-size:14pt;color:var(--muted);font-style:italic;margin-top:10px}
.sealed{display:inline-block;font-size:8pt;letter-spacing:2px;text-transform:uppercase;padding:5px 10px;border-radius:5px;font-weight:700;
  background:rgba(201,154,58,.16);color:var(--amber);border:1px solid rgba(201,154,58,.45)}
.sealed.red{background:rgba(194,74,63,.16);color:var(--red);border-color:rgba(194,74,63,.45)}
.tag{display:inline-block;font-size:7.5pt;letter-spacing:1.5px;text-transform:uppercase;padding:2px 7px;border-radius:4px;font-weight:700;vertical-align:middle}
.tag.g{background:rgba(31,177,85,.16);color:var(--green)}
.tag.a{background:rgba(201,154,58,.16);color:var(--amber)}
.tag.r{background:rgba(194,74,63,.16);color:var(--red)}
.tag.m{background:rgba(244,245,240,.08);color:var(--muted)}
.tag.b{background:rgba(143,214,166,.14);color:#8fd6a6}
.banner{background:rgba(201,154,58,.10);border:1px solid rgba(201,154,58,.40);border-radius:10px;padding:10px 14px;margin:0 0 16px;font-size:10.5pt}
.banner.red{background:rgba(194,74,63,.10);border-color:rgba(194,74,63,.40)}
.banner.green{background:rgba(31,177,85,.10);border-color:rgba(31,177,85,.40)}
.sec{margin-top:22px}
.sec > h2{break-after:avoid}
.sec > .lede{break-after:avoid}
.sec > h2{font-size:17pt;margin-bottom:4px}
.sec > .lede{color:var(--muted);font-size:10pt;margin:0 0 12px;max-width:80ch}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin-bottom:12px;break-inside:avoid}
.panel.flow{break-inside:auto}
tr{break-inside:avoid}
.panel h3{break-after:avoid}
.panel h3{font-size:13.5pt;margin-bottom:4px}
.panel .ph-sub{color:var(--muted);font-size:9.5pt;margin-bottom:10px}
p{margin:0 0 10px}
.persona p{font-size:11.2pt;max-width:82ch}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
.grid4{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.stake{padding:8px 0;border-bottom:1px solid var(--line)}
.stake:last-child{border:none}
.stake b{display:block;font-family:var(--serif);font-size:11.5pt}
.stake span{color:var(--muted);font-size:10.3pt}
ul{margin:0;padding-left:18px}
li{margin:4px 0;font-size:10.5pt}
.do h3{color:var(--green)} .dont h3{color:var(--red)}
.glance{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:12px 14px}
.glance .q{font-family:var(--serif);font-size:18pt;color:var(--green);line-height:1}
.glance .post{font-size:9.5pt;color:var(--text);margin-top:4px;min-height:2.6em}
.glance .n{font-family:var(--mono);font-size:9pt;color:var(--muted);margin-top:6px}
.glance .n b{color:var(--text)}
.qpanel{break-inside:auto;background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:0;margin-bottom:12px}
.qhead{display:flex;align-items:flex-start;gap:14px;padding:12px 18px;background:var(--panel2);border-bottom:1px solid var(--line);border-radius:12px 12px 0 0;break-after:avoid}
.qhead .mid{flex:1}
.need,.show,.trap,.recov{break-inside:avoid}
.qbody h4{break-after:avoid}
.qhead .q{font-family:var(--serif);font-size:22pt;color:var(--green);line-height:1}
.qhead .posture{font-family:var(--serif);font-size:13.5pt}
.qhead .line{font-family:var(--serif);font-style:italic;color:var(--muted);font-size:10.5pt;margin-top:2px}
.qhead .cap{font-family:var(--mono);font-size:8.5pt;color:var(--amber);white-space:nowrap;margin-left:auto;padding-top:6px}
.qbody{padding:12px 18px 14px}
.qbody h4{font-size:8.5pt;letter-spacing:1.5px;text-transform:uppercase;color:var(--faint);font-family:var(--body);font-weight:700;margin:10px 0 5px}
.qbody h4:first-child{margin-top:0}
.need{display:flex;gap:10px;align-items:baseline;padding:4px 0;font-size:10.5pt}
.need .t{font-weight:700;min-width:15ch}
.need .w{color:var(--muted)}
.show{display:flex;gap:10px;align-items:baseline;padding:3px 0;font-size:10.3pt}
.show .t{font-weight:700;min-width:15ch}
.show .w{color:var(--muted)}
.trap{margin-top:10px;background:rgba(194,74,63,.09);border-left:3px solid var(--red);padding:8px 12px;border-radius:0 8px 8px 0;font-size:10.3pt}
.trap b{color:var(--red);font-family:var(--serif);letter-spacing:.3px}
.recov{margin-top:8px;background:rgba(31,177,85,.08);border-left:3px solid var(--green);padding:8px 12px;border-radius:0 8px 8px 0;font-size:10.3pt}
.recov b{color:var(--green);font-family:var(--serif)}
table{width:100%;border-collapse:collapse;font-size:10pt}
th,td{text-align:left;padding:7px 9px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:8pt;letter-spacing:1px;text-transform:uppercase;color:var(--faint);font-weight:700}
td.mono{font-family:var(--mono);font-size:9.5pt}
.rub .score{font-family:var(--serif);font-size:15pt;color:var(--green);width:3ch}
.rub .s2{color:var(--amber)} .rub .s1{color:var(--red)}
.judge{font-family:var(--serif);font-size:12pt;line-height:1.5;padding:16px 18px;border:1px solid rgba(31,177,85,.4);border-radius:12px;background:rgba(31,177,85,.06)}
.rules li{font-size:10.5pt}
.foot{margin-top:26px;padding-top:10px;border-top:1px solid var(--line);display:flex;justify-content:space-between;color:var(--faint);font-size:8.5pt;font-family:var(--mono)}
.pb{break-before:page}
.dir-t td:first-child{white-space:nowrap}
.dir-t .tx{font-family:var(--serif);font-size:10.5pt}
.dir-t .ben{color:var(--muted);font-size:9.5pt}
.callout{font-family:var(--serif);font-size:12pt;color:var(--text);padding:12px 16px;border-left:3px solid var(--amber);background:rgba(201,154,58,.07);border-radius:0 8px 8px 0;margin:8px 0 12px}
.beat{display:flex;gap:12px;padding:8px 0;border-bottom:1px solid var(--line)}
.beat:last-child{border:none}
.beat .n{font-family:var(--serif);font-size:16pt;color:var(--green);width:2ch;line-height:1.1}
.beat .b b{font-family:var(--serif);font-size:11.5pt;display:block}
.beat .b span{color:var(--muted);font-size:10.3pt}
"""

def esc(s): return _h.escape(str(s), quote=False)

SHOW_TAG = {
    "aligned":    ("g", "aligned directive"),
    "tension":    ("r", "tension directive"),
    "unprompted": ("b", "unprompted"),
    "unlikely":   ("m", "probably not"),
    "recovery":   ("a", "recovery path"),
    "none":       ("m", "no demand"),
}

def masthead(c, sealed_label="Character brief · sealed", sealed_cls=""):
    return f"""
<div class="mast">
  <div>
    <div class="brand">Praxis · Case 03 · Borrowed People</div>
    <div class="sub">The Uncomfortable Art of Leadership · Leadership-Comp</div>
    <div class="name">{c['name']}</div>
    <div class="role">{c['role']}</div>
    <div class="tagline">{c['tagline']}</div>
  </div>
  <div style="text-align:right">
    <span class="sealed {sealed_cls}">{sealed_label}</span>
    <div class="sub" style="margin-top:10px">{VERSION}</div>
  </div>
</div>"""

def footer(c, page_note=""):
    return f"""<div class="foot"><span>PRAXIS · BORROWED PEOPLE · {c['name'].upper()} · SEALED</span><span>{page_note}{VERSION}</span></div>"""

def render_character(c):
    dm = demand_for(c["key"])
    counts = {q: (sum(1 for _, k in cells if k == "PRIMARY"), sum(1 for _, k in cells if k == "SECONDARY")) for q, cells in dm}
    total_cells = sum(len(cells) for _, cells in dm)
    named = sum(1 for v in DIRECTED.values() if v == c["key"])

    # --- at a glance
    glance = ""
    for q in range(1, 5):
        p, s = counts[q]
        post, _ = POSTURE[q]
        qd = c["quarters"][q - 1]
        glance += f"""<div class="glance"><div class="q">Q{q}</div><div class="post">{esc(post)}</div>
          <div class="n">slots <b>{qd['cap']}</b> · needs <b>{p+s}</b> <span style="color:var(--faint)">({p}P/{s}S)</span></div></div>"""

    # --- stakes
    stakes = "".join(f'<div class="stake"><b>{esc(t)}</b><span>{esc(x)}</span></div>' for t, x in c["stakes"])
    do = "".join(f"<li>{esc(x)}</li>" for x in c["do"])
    dont = "".join(f"<li>{esc(x)}</li>" for x in c["dont"])

    # --- quarters
    qhtml = ""
    for qd in c["quarters"]:
        q = qd["q"]; post, line = POSTURE[q]
        needs = "".join(
            f'<div class="need"><span class="t">{esc(T(code))}</span><span class="tag {"g" if k=="PRIMARY" else "a"}">{k.lower()}</span><span class="w">{esc(why)}</span></div>'
            for code, k, why in qd["needs"]) or '<div class="need"><span class="w">Nobody. You are on no team’s path this quarter.</span></div>'
        shows = ""
        for code, kind, txt in qd["show"]:
            cls, lbl = SHOW_TAG[kind]
            tname = T(code) if code in TEAMS else "—"
            shows += f'<div class="show"><span class="t">{esc(tname)}</span><span class="tag {cls}">{lbl}</span><span class="w">{esc(txt)}</span></div>'
        recov = f'<div class="recov"><b>Recovery path.</b> {qd["recovery"]}</div>' if qd.get("recovery") else ""
        qhtml += f"""
<div class="qpanel">
  <div class="qhead"><div class="q">Q{q}</div><div class="mid"><div class="posture">{esc(post)}</div>
    <div class="line">{esc(line)}</div></div><div class="cap">capacity · {qd['cap']} team(s)</div></div>
  <div class="qbody">
    <h4>Who the work actually needs from you <span class="tag r" style="margin-left:6px">sealed</span></h4>{needs}
    <h4>Who will probably show up — and why</h4>{shows}
    <div class="trap"><b>The trap.</b> {esc(qd['trap'])}</div>
    {recov}
  </div>
</div>"""

    # --- capacity table
    caprows = ""
    for qd in c["quarters"]:
        q = qd["q"]; p, s = counts[q]
        likely = sum(1 for _, kind, _ in qd["show"] if kind in ("aligned", "tension", "recovery"))
        wrong = sum(1 for code, kind, _ in qd["show"] if kind == "tension" and not any(cc == code for cc, _, _ in qd["needs"]))
        note = []
        if p + s > qd["cap"]: note.append("squeeze — someone misses")
        if wrong: note.append(f"{wrong} misdirected ask")
        if p + s == 0: note.append("no genuine demand")
        caprows += f'<tr><td class="mono">Q{q}</td><td class="mono">{qd["cap"]}</td><td class="mono">{p} primary · {s} secondary</td><td class="mono">≈{likely}</td><td>{esc("; ".join(note) or "clean")}</td></tr>'

    # --- rubric
    rub = ""
    for key, label, hint in RUBRIC:
        a3, a2, a1 = c["rubric_anchors"][key]
        rub += f"""<div class="panel rub"><h3>{esc(label)}</h3><div class="ph-sub">{esc(hint)}</div>
          <table><tr><td class="score">3</td><td>{esc(a3)}</td></tr>
                 <tr><td class="score s2">2</td><td>{esc(a2)}</td></tr>
                 <tr><td class="score s1">1</td><td>{esc(a1)}</td></tr></table></div>"""

    persona = "".join(f"<p>{p}</p>" for p in c["persona"])

    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Praxis · Borrowed People · {esc(c['name'])} — character brief</title><style>{CSS}</style></head>
<body>
<div class="bleed"></div>
<div class="page">
{masthead(c)}
<div class="banner red"><b>Sealed.</b> This brief is yours alone. Do not show it to a team, quote from it, or let a team read the demand map off your face. Everything marked <span class="tag r">sealed</span> is something you <i>feel</i> as instinct in the room — never something you cite.</div>

<div class="sec"><h2>Who you are</h2><div class="persona">{persona}</div></div>

<div class="sec"><h2>Your year at a glance</h2>
<div class="lede">The work needs you in <b>{total_cells}</b> team-quarters across the year. The Sponsor sends a team to you in <b>{named}</b> of the 20 directives. The gap between those two numbers is your story.</div>
<div class="grid4">{glance}</div></div>

<div class="sec"><h2>What you actually care about</h2>
<div class="lede">This is what “knew what I cared about” means when a team sits down with you. If they can’t touch one of these, they don’t know you.</div>
<div class="panel">{stakes}</div></div>

<div class="sec"><h2>How to play it</h2>
<div class="grid2">
  <div class="panel do"><h3>Do</h3><ul>{do}</ul></div>
  <div class="panel dont"><h3>Don’t</h3><ul>{dont}</ul></div>
</div></div>

<div class="sec"><h2>How the engine uses you</h2>
<div class="panel"><ul>
<li>A team only gets credit for you if <b>you select them</b> at SELECTION. Being asked is not enough; your two slots decide objectives.</li>
<li>Your three 1–3 ratings are averaged with the other characters who picked that team and feed their annual band. Rate honestly — the facilitator runs a <b>drift check</b> for rating compression, and a character who goes soft quietly breaks the case.</li>
<li>Each quarter has a posture card. Play it straight even when a team is likeable; the escalation is the arc: <i>vague → competing claims → refuse → judge</i>.</li>
<li>If a team missed the person they needed last quarter, the engine marks them <b>behind</b> and rewrites their ideal: last quarter’s primary first, this quarter’s second. Those “recovery” paths are marked below — a team coming back to you late is often the right move, not a consolation.</li>
</ul></div></div>

<div class="sec" style="margin-top:8px"><h2>The year, quarter by quarter</h2>
<div class="lede">Posture and sample line are from your console card. “Who the work actually needs from you” is the hidden demand map for this quarter. “Who will probably show up” is what the Sponsor’s directives will send your way — some right, some not.</div>
{qhtml}
</div>
<div class="sec" style="margin-top:8px"><h2>Capacity and the squeeze</h2>
<div class="lede">Two slots every quarter. Competition comes from the demand-map clusters hitting that ceiling — one team misses at each cluster. That’s real rivalry without famine.</div>
<div class="panel"><table><thead><tr><th>Quarter</th><th>Slots</th><th>Genuine need</th><th>Likely asks</th><th>Read</th></tr></thead><tbody>{caprows}</tbody></table></div></div>

<div class="sec"><h2>How you rate</h2>
<div class="lede">Three scores, 1–3, for every team you selected. Fixed rubric, your anchors. 1 = poor, 3 = strong. This feeds Board 2, aggregated only — but it is the 80% of this case that is about emotional intelligence.</div>
{rub}</div>

<div class="sec"><h2>Q4 — your judgement</h2>
<div class="lede">In Q4 the console opens a verdict for every team: <b>work with again</b>, or <b>would not</b> — and why. It is read out to the room. Say it plainly.</div>
<div class="judge">{esc(c['judgement'])}</div></div>

<div class="sec"><h2>Sealed rules</h2>
<div class="panel rules"><ul>
<li>Never name who the “right” person is for a team’s problem. You may say what kind of problem it isn’t.</li>
<li>Never reference quarters as if you know the plan (“you’ll need me in Q4”). You don’t — officially.</li>
<li>Never disclose your capacity to a team before selection, and never promise a slot in negotiation.</li>
<li>Never confirm or deny that a Sponsor directive was right. That is the reveal’s job, not yours.</li>
<li>When in doubt: hold the posture card, ask for the constraint, and let silence work.</li>
</ul></div></div>
{footer(c)}
</div>
</body></html>"""


def render_sponsor(c):
    stakes = "".join(f'<div class="stake"><b>{esc(t)}</b><span>{esc(x)}</span></div>' for t, x in c["stakes"])
    do = "".join(f"<li>{esc(x)}</li>" for x in c["do"])
    dont = "".join(f"<li>{esc(x)}</li>" for x in c["dont"])
    persona = "".join(f"<p>{p}</p>" for p in c["persona"])

    # directive schedule by quarter
    QNOTE = {
        1: ("All aligned", "Teach the mechanic. Build trust — every directive points at the ideal."),
        2: ("Warm-up · 2 tension", "Bastion → Raghav (partial). Envoy → Arjun (partial). Cell-price curveball lands here."),
        3: ("Peak · 3 tension", "Ampere → Arjun, Crucible → Raghav, Dynamo → Farida — all hard misses. Capacity crunch on Raghav. Quality-escape curveball lands here."),
        4: ("Resolution · 1 tension", "Envoy told not to escalate — the false self-sufficiency trap. You have 2 slots against 3 who need you."),
    }
    sched = ""
    for q in range(1, 5):
        rows = ""
        for team, qq, al, txt, ben, note in DIRECTIVES:
            if qq != q: continue
            p, s = DMAP[team][q - 1]
            ideal = NAMES[p] + (f" / {NAMES[s]}" if s != p else "")
            tag = '<span class="tag g">aligned</span>' if al == "sound" else '<span class="tag r">tension</span>'
            if note == "escalate": tag = '<span class="tag g">aligned · escalate</span>'
            nt = f'<div class="ben">{esc(note)}</div>' if note and note != "escalate" else ""
            rows += f'<tr><td><b>{esc(T(team))}</b><div class="ben">ideal: {esc(ideal)}</div></td><td>{tag}{nt}</td><td class="tx">“{esc(txt)}”</td><td class="ben">{esc(ben)}</td></tr>'
        title, sub = QNOTE[q]
        sched += f"""<div class="panel flow"><h3>Q{q} — {esc(title)}</h3><div class="ph-sub">{esc(sub)}</div>
        <table class="dir-t"><thead><tr><th>Team</th><th>Call</th><th>Say this at BRIEF</th><th>Intended benefit</th></tr></thead><tbody>{rows}</tbody></table></div>"""

    postures = "".join(
        f'<tr><td class="mono">Q{q}</td><td><b>{esc(p)}</b></td><td style="font-family:var(--serif);font-style:italic;color:var(--muted)">{esc(l)}</td><td class="mono">{2 if q==4 else 1}</td></tr>'
        for q, (p, l) in POSTURE.items())

    cells = [
        ("comply", "sound", "trust well-placed"), ("comply", "tension", "silent compliance"),
        ("voice", "sound", "reconciled"), ("voice", "tension", "the leadership move"),
        ("defy", "sound", "parochial overreach"), ("defy", "tension", "principled dissent"),
    ]
    cellrows = "".join(f'<tr><td class="mono">{st}</td><td class="mono">{al}</td><td><b>{lbl}</b></td></tr>' for st, al, lbl in cells)

    curve = [
        ("Cell prices +6%", "Q2", "Bastion Q2 (→Raghav trap); validates Ampere’s aligned supply pick", "Makes Bastion’s “harder terms via Raghav” directive feel right, when the shock actually screams secure-supply / Neha. For Ampere it confirms the correct call — reward the team that reads it."),
        ("Field quality escape", "Q3", "Crucible Q3 (→Raghav, stop iterating) + Dynamo Q3 (→Farida testing)", "Puts Spec and Warranty in direct conflict exactly when both have tension directives pulling them the wrong way."),
        ("Character pulled", "Q3 or Q4", "whichever character the herd over-concentrated on", "Fires AFTER requests lock. Pull the character the tension directives + herd funnelled everyone toward (watch the drift / monitor tab). Punishes teams that didn’t diversify — the scarcity lesson made physical."),
        ("Sponsor praise", "Q2 or Q3, post-results", "the political / social lever", "(a) Praise a team that Voiced or defied correctly, to reinforce principled leadership publicly; or (b) praise a team that complied with a tension directive and watch others copy the wrong behaviour — a devastating debrief reveal: “you followed them because I blessed them.”"),
    ]
    curverows = "".join(f'<tr><td><b>{esc(a)}</b></td><td class="mono">{esc(b)}</td><td>{esc(c_)}</td><td class="ben">{esc(d)}</td></tr>' for a, b, c_, d in curve)

    beats = [
        ("The number", "1 min", "Org net vs floor + ranks. Set the stakes, fast."),
        ("The reveal", "2 min", "Unhide each team’s adjusted ideal + business reason. Let got_p / got_s land. Business only here."),
        ("One sharp contrast", "3–4 min", "Data picks the 1–2 teams with the biggest gap. Hand the mic to a character or the observer, not yourself: “Neha, how did that ask feel?” This is where EI enters."),
        ("Relitigate the Mandate", "2 min", "Show the Comply / Voice / Defy split now results are visible; read one dissent line. “Knowing what you know now — right call?”"),
        ("Forward challenge", "30 s", "One sentence that seeds the next round’s tension."),
    ]
    beathtml = "".join(f'<div class="beat"><div class="n">{i+1}</div><div class="b"><b>{esc(t)} <span class="tag m">{esc(d)}</span></b><span>{esc(x)}</span></div></div>' for i, (t, d, x) in enumerate(beats))

    themes = [("Q1", "Did you find the right people?", "got_p / got_s + ratings"),
              ("Q2", "Follow or lead?", "Mandate split + style gap"),
              ("Q3", "Scarcity & the cost of the herd", "capacity squeeze + collaboration tax"),
              ("Q4", "Judgement", "characters’ “work with you again?” + couplings")]
    themerows = "".join(f'<tr><td class="mono">{q}</td><td><b>{esc(f)}</b></td><td class="ben">{esc(a)}</td></tr>' for q, f, a in themes)

    signals = [("Request vs demand map", "“You went to Raghav; the work needed Farida. What made you pick him?”"),
               ("Ratings — left me better", "“You got what you needed — did she?”"),
               ("Mandate stance", "“You defied and were right — but never told the Sponsor. What did the silence cost?”"),
               ("Style call vs observed", "“You called ‘coaching.’ The room saw ‘commanding.’ Where’s the gap?”"),
               ("Commitments broken", "“You promised Envoy support and didn’t deliver — Envoy, how did that land?”")]
    sigrows = "".join(f'<tr><td><b>{esc(s)}</b></td><td style="font-family:var(--serif);font-style:italic">{esc(a)}</td></tr>' for s, a in signals)

    return f"""<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Praxis · Borrowed People · The Sponsor — operator brief</title><style>{CSS}</style></head>
<body>
<div class="bleed"></div>
<div class="page">
{masthead(c, "Operator brief · facilitator only", "red")}
<div class="banner red"><b>Facilitator only.</b> This document contains the full directive schedule, the alignment of every directive against the hidden demand map, the curveball map and the debrief card. It never leaves the Sponsor screen.</div>

<div class="sec"><h2>Who you are</h2><div class="persona">{persona}</div></div>

<div class="sec"><h2>What you actually care about</h2><div class="panel">{stakes}</div></div>

<div class="sec"><h2>How to play it</h2>
<div class="grid2">
  <div class="panel do"><h3>Do</h3><ul>{do}</ul></div>
  <div class="panel dont"><h3>Don’t</h3><ul>{dont}</ul></div>
</div></div>

<div class="sec"><h2>Your posture and capacity, by quarter</h2>
<div class="lede">The same escalation cards the working characters hold — you play them too, as the most senior person in the building. Your capacity is the tightest in the room.</div>
<div class="panel"><table><thead><tr><th>Quarter</th><th>Posture</th><th>Sample line</th><th>Your slots</th></tr></thead><tbody>{postures}</tbody></table></div>
<div class="callout">Q4 is your crunch: Bastion, Crucible and Envoy all need you as primary; you have two slots; Envoy has been told not to come. If only two show, you are not relieved — Envoy’s absence is the failure of not asking for help, and it is the last thing the room should hear before the final debrief.</div></div>
<div class="sec" style="margin-top:8px"><h2>The directive schedule</h2>
<div class="lede">Issued at <b>BRIEF</b> each quarter, one per team, in your voice. Every directive is sincere. <span class="tag g">aligned</span> points at the quarter’s ideal primary. <span class="tag r">tension</span> conflicts with it: complying misses <code>got_primary</code>, the team goes <b>behind</b>, and the adaptive map hands them a recovery pick next quarter. Design rule: no team has two consecutive primary-miss directives.</div>
{sched}
</div>
<div class="sec" style="margin-top:8px"><h2>The Voice lever and the leadership cell</h2>
<div class="lede">Each team declares a stance on your directive before requests lock: <b>Comply</b>, <b>Voice</b> (push back, then act), or <b>Defy</b>. Stance × the directive’s real alignment gives the leadership cell the reveal shows. Directives are written against the base plan — once a team is behind, the ideal shifts to the recovery pick, so a base directive can read as off-target for that team. That is the moment to use Voice: when a behind team surfaces its situation, re-issue a recovery directive live. Don’t static-proof every path; let facilitation heal it.</div>
<div class="grid2">
<div class="panel"><h3>Leadership cell</h3><table><thead><tr><th>Stance</th><th>Directive was</th><th>Cell</th></tr></thead><tbody>{cellrows}</tbody></table></div>
<div class="panel"><h3>Re-issuing live</h3><ul>
<li>Listen as the executive would: “What are you seeing that I’m not?”</li>
<li>If the team has surfaced a real gap (the missed prerequisite, a curveball they read correctly), re-issue: “Fine — recover with Neha first, then bring Raghav.” In your voice. Sincere.</li>
<li>If the team is pushing back on a sound directive with nothing behind it, hold. That is “parochial overreach,” and the reveal will say so.</li>
<li>Never reward the pushback itself. Reward the reasoning.</li>
</ul></div></div></div>

<div class="sec"><h2>Curveball map</h2>
<div class="lede">Four are seeded. Drop each at the BRIEF of the quarter where it amplifies a live tension directive. The escalation posture already tracks this: Q2 competing claims pairs with cell-price scarcity, Q3 refusal pairs with the escape + the pulled character, Q4 judges.</div>
<div class="panel"><table><thead><tr><th>Curveball</th><th>Best quarter</th><th>Amplifies</th><th>Why it bites</th></tr></thead><tbody>{curverows}</tbody></table></div></div>
<div class="sec" style="margin-top:8px"><h2>Between-round debrief card</h2>
<div class="lede">Prep in the RESULTS window (~2 min, while the engine scores). You get three things for free: the <b>scoreboard</b> (org net vs floor, ranks), the <b>adjusted reveal</b> (each team’s state-adjusted ideal + one-line business reason — path-dependent), and <b>bp-assist → Analyze now</b> (key moves, contradictions & risks, pointed questions). Walk in with a plan.</div>
<div class="grid2">
<div class="panel"><h3>The five beats · 8–10 min</h3>{beathtml}</div>
<div>
<div class="panel"><h3>Rotate the theme</h3><table><thead><tr><th></th><th>Foreground</th><th>Anchor</th></tr></thead><tbody>{themerows}</tbody></table></div>
<div class="panel"><h3>Two rules</h3><ul>
<li><b>Business in the reveal; EI in the room.</b> The adjusted map says the smart business move. You bring whether they could get that person to help — and how.</li>
<li><b>Can’t debrief five teams every round.</b> Spotlight the 1–2 sharpest contrasts; rotate so everyone gets a turn by Q4. Full per-team synthesis waits for the final debrief.</li>
</ul></div></div></div></div>

<div class="sec"><h2>Data → the question it authorises</h2>
<div class="panel"><table><thead><tr><th>Signal</th><th>Ask</th></tr></thead><tbody>{sigrows}</tbody></table></div></div>

<div class="sec"><h2>Sealed rules for the Sponsor</h2>
<div class="panel rules"><ul>
<li>Never confirm a directive is a trap — not in tone, not in a pause, not in a smile at the character who knows.</li>
<li>Never reveal the demand map before the RESULTS reveal, and never reveal a team’s state (behind / at risk) before the engine does.</li>
<li>Your one slot in Q1–Q3 is real. A team that reaches you early has spent political capital; make it feel that way in character.</li>
<li>Praise is a lever, not a courtesy. Decide before you use it whether you are reinforcing or baiting.</li>
<li>When a behind team Voices, that is the lever working. Re-issue, and log it.</li>
</ul></div></div>
{footer(c)}
</div>
</body></html>"""


def to_pdf(html_path, pdf_path, tmp_profile, wait_s=45):
    """Print with Chrome headless. On macOS Chrome sometimes writes the PDF and
    then never exits, so poll for a stable output file and terminate it."""
    import time
    if os.path.exists(pdf_path):
        os.remove(pdf_path)
    cmd = [CHROME, "--headless", "--disable-gpu", "--no-sandbox", "--no-first-run",
           "--no-default-browser-check", f"--user-data-dir={tmp_profile}",
           "--no-pdf-header-footer", f"--print-to-pdf={pdf_path}", "file://" + html_path]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    last = -1; stable = 0; deadline = time.time() + wait_s
    while time.time() < deadline:
        time.sleep(0.5)
        if os.path.exists(pdf_path):
            sz = os.path.getsize(pdf_path)
            stable = stable + 1 if sz == last and sz > 0 else 0
            last = sz
            if stable >= 2:
                break
        if proc.poll() is not None and os.path.exists(pdf_path):
            break
    try:
        proc.terminate(); proc.wait(timeout=5)
    except Exception:
        proc.kill()
    if not os.path.exists(pdf_path) or os.path.getsize(pdf_path) == 0:
        raise RuntimeError(f"Chrome produced no PDF for {html_path}")


def main():
    os.makedirs(HTML_DIR, exist_ok=True)
    os.makedirs(PDF_DIR, exist_ok=True)
    tmp_profile = os.environ.get("BRIEFS_CHROME_PROFILE") or os.path.join(HERE, ".chrome-profile")
    os.makedirs(tmp_profile, exist_ok=True)
    built = []
    for c in CHARACTERS + [SPONSOR]:
        html_out = os.path.join(HTML_DIR, f"{c['key']}.html")
        pdf_out = os.path.join(PDF_DIR, f"Praxis-BorrowedPeople-Brief-{c['name'].replace('The ', '')}.pdf")
        with open(html_out, "w", encoding="utf-8") as f:
            f.write(render_sponsor(c) if c["key"] == "sponsor" else render_character(c))
        if not os.path.exists(CHROME):
            print(f"[warn] Chrome not found at {CHROME}; wrote HTML only: {html_out}")
            continue
        to_pdf(html_out, pdf_out, tmp_profile)
        built.append(pdf_out)
        print(f"ok  {os.path.relpath(pdf_out, HERE)}")
    shutil.rmtree(tmp_profile, ignore_errors=True)
    return built


if __name__ == "__main__":
    main()
