# Hosting Praxis on Netlify (hides the source repo, one shareable URL)

The app is static files (`enter.html`, `app.html`, `borrowed.html`, …) plus the
Supabase backend. Netlify serves them from a neutral domain while the GitHub
repo can stay **private**, so the repo isn't discoverable from the URL.

> The Supabase **anon key** is embedded in the pages (by design — it's public,
> and Row Level Security protects all data). Hosting hides the *source repo*,
> not the anon key. That's expected and safe.

## One-time setup (in the Netlify UI — you must do this; it needs your login)

1. **Netlify → Add new site → Import an existing project → GitHub.**
2. Authorize Netlify for your GitHub account if prompted, and pick
   **`Yaswant46/praxis`**.
3. Build settings:
   - **Build command:** *(leave empty)*
   - **Publish directory:** `.`
   - (These are already declared in `netlify.toml`, so Netlify will pick them up.)
4. **Deploy.** Netlify builds on every push to your production branch (`main`).

If you'd rather use your **existing** Netlify site instead of a new one:
**Site configuration → Build & deploy → Continuous deployment → Link repository**
→ choose `Yaswant46/praxis`, branch `main`, publish `.`.

## Make the repo private (so the link doesn't expose the code)

GitHub → repo **Settings → General → Danger Zone → Change visibility → Private**.
Netlify keeps deploying from a private repo on its free tier. (GitHub Pages,
by contrast, needs a paid plan to serve a private repo — which is why moving to
Netlify is the clean path.)

> Turning the repo private also takes down the old GitHub Pages URL
> (`yaswant46.github.io/praxis`). Point people at the Netlify URL from then on.

## The single URL you share

Once deployed, share **`https://<your-site>.netlify.app/join`** (a clean alias
for `enter.html`). Participants enter their **cohort code + email** and are
routed straight to their seat. A custom domain can be added later under
**Domain management**.

## Optional — gate the whole site behind a login

If you want *only invited people* to even reach the app (not just anyone with
the link), use **Netlify password protection** (paid) or **Cloudflare Access**
(free tier) in front of the site. The app already requires a valid cohort
code + registered email to do anything, so this is optional hardening.
