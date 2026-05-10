# Praxis — Catalyst Leadership Simulation

Live business simulation platform for the Ather Catalyst Programme.

A Game Master logs in via OTP, runs the **Create Cohort** wizard (cohort name,
case, number of teams, number of rounds, one rep email per team), and the
system generates themed team names + memorable passwords and emails them to
each rep with a unique cohort URL. Each team logs in with their username +
password and runs the simulation in real time.

---

## Architecture

| Layer       | Tech                                       |
|-------------|--------------------------------------------|
| Frontend    | Static `app.html` on GitHub Pages          |
| Database    | Supabase Postgres (RLS + RPCs)             |
| Realtime    | Supabase Realtime (WebSockets)             |
| Auth (GM)   | Supabase OTP (email)                       |
| Auth (team) | `verify_team_login` RPC (session + creds)  |
| Email       | Supabase Edge Function → Resend            |

---

## One-time setup

You only do this once per Supabase project.

### 1. Run the schema

Go to **Supabase → SQL Editor → New Query**, paste `supabase_schema.sql`, and
**Run**. Idempotent — safe to re-run if you change the file later.

### 2. Set up Resend

1. Sign up at [resend.com](https://resend.com).
2. Verify a sender domain (or use the resend.dev sandbox for testing).
3. Copy your API key from the Resend dashboard.

### 3. Configure Supabase secrets

```bash
supabase secrets set \
  RESEND_API_KEY=re_...your_key... \
  PRAXIS_FROM_EMAIL=praxis@your-verified-domain.com \
  PRAXIS_APP_BASE_URL=https://yaswant46.github.io/praxis
```

### 4. Deploy the Edge Function

```bash
supabase functions deploy send-cohort-emails
```

### 5. Upload case PDFs

Add to `assets/cases/`:

- `volta_case.pdf`
- `arc_case.pdf`
- `demo_case.pdf`

### 6. Publish to GitHub Pages

**Repo Settings → Pages → Source: main / (root) → Save.**
Live at `https://yaswant46.github.io/praxis`.

---

## Running a cohort

1. **GM logs in** at the live URL → "Game Master" → enters email → 6-digit OTP.
2. Lands on **GM Console** (or **Master Admin** for `ross.harvey92@gmail.com`).
3. Click **+ Create New Cohort** → fills cohort name, case, team count
   (2–6), rounds (1..max for the chosen case), GM email.
4. **Step 2 — Team representatives**: enter one rep email per team. Themed
   names + passwords are pre-generated; click ↻ to regenerate, or just edit.
5. Click **Create cohort & send emails**. The Edge Function fires one Resend
   email per team rep with username, password, and a unique URL.
6. Each rep forwards the email to teammates. Anyone on the team can then
   open the URL, enter the username + password, and play.
7. The GM enters the cohort from the console (**Enter as GM**) to run the
   simulation: open/close rounds, inject curveballs, publish outcomes.

The GM can **resend** an email to a single team or rotate a team's password
from the Manage panel at any time.

---

## Files

| File                                          | What it is                                  |
|-----------------------------------------------|---------------------------------------------|
| `index.html`                                  | Landing page (redirects to `app.html`)      |
| `app.html`                                    | The whole app — UI, JS, Supabase client     |
| `supabase_schema.sql`                         | Tables, RLS policies, RPCs, realtime config |
| `supabase/functions/send-cohort-emails/`      | Deno Edge Function (Resend transport)       |
| `404.html`                                    | GitHub Pages SPA fallback                   |

---

## Security model

- **Game Master writes** (creating cohorts, opening rounds, injecting
  curveballs, publishing outcomes) require an authenticated Supabase
  session whose email matches the cohort's `admin_email` — enforced by
  RLS, not just client-side checks.
- **Team credentials** (`username`, `password`) are never readable by the
  anon role. The participant login goes through the `verify_team_login`
  RPC which returns the team identity only on a credential match.
- **Outcomes** are visible to participants only after the GM publishes
  them (`published_at IS NOT NULL`).
- **Decisions** remain readable across teams in this version. The next
  iteration will gate them with per-team JWTs issued by `verify_team_login`.

The hardcoded master-admin email is `ross.harvey92@gmail.com`. To change
it, edit both `app.html` (`SUPERUSER_EMAIL`) and
`supabase_schema.sql` (the `praxis_is_master_admin` helper).
