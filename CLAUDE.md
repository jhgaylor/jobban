# jobban — project context

Job-search kanban for Jake (jhgaylor). Phoenix LiveView 1.8, single-user,
deployed on the home-cloud k3s cluster at https://jobban.inevitable.fyi —
publicly readable, writes gated behind GitHub SSO via `/login`. Generic
Phoenix/LiveView guidance lives in @AGENTS.md; this file is the
project-specific context.

## Architecture (and why)

- **Two LiveViews** share one context. `JobbanWeb.BoardLive` renders the
  public kanban; `JobbanWeb.LaunchpadLive` (`/launchpad`, admin-only) is the
  prep view (see Launchpad below). All mutations go through the `Jobban.Board`
  context, which broadcasts `{:board_changed}` on the `"board"` PubSub topic;
  both views subscribe and reload. Coarse-grained on purpose — a personal
  board is small, and "reload everything" keeps move/reindex logic trivially
  correct.
- **Stages are DB rows** (seeded idempotently in `priv/repo/seeds.exs`:
  wishlist, applied, interviewing, offer, rejected). UI accent colors map
  by slug in `BoardLive.@stage_styles` (compile-time class strings so
  Tailwind JIT sees them). Slug-based behavior: drop into `offer` fires
  confetti; `rejected`/`offer`/`wishlist` suppress the aging badge.
- **Card ordering** is an integer `position` per stage, renumbered in a
  transaction on every move (`Board.move_job/3`). `stage_entered_at` resets
  only when the stage changes — it drives the days-in-stage aging badges
  (amber ≥3d, red ≥7d).
- **Activities** are the per-job timeline: `created`/`moved` are logged
  automatically, `note` is user input (multi-line; rendered
  `whitespace-pre-line`). There is no separate "interview" model by
  choice — Jake wanted interview details as plain notes.
- **ATS-link import** (`Jobban.Importer`): tiered extraction —
  schema.org JobPosting JSON-LD → OpenRouter LLM over page text
  (`Jobban.LLM.OpenRouter`, mirrors grocery-aid's client; skipped without
  a key) → Greenhouse `<title>` pattern + OpenGraph meta. Runs via
  `start_async` with a skeleton card. LLM is an enhancement, never a
  dependency — any LLM failure falls back to deterministic results.
- **Auth** (`JobbanWeb.Auth`): board is public read-only; writes unlock
  via the cluster's existing GitHub SSO (oauth2-proxy whitelisting
  jhgaylor) — no password, no user records, no app-specific GitHub OAuth
  app. Only `/login` is wrapped in the `github-auth-signin`/`github-auth`
  forwardAuth middlewares (`k8s/ingressroute.yaml`; longer Traefik rule
  outranks the public catch-all). Traefik overwrites `x-auth-request-user`
  with the verified login there, `AuthController` compares it to
  `:github_user` (env `ADMIN_GITHUB_USER`, default jhgaylor) and sets a
  session flag. Enforcement is server-side — a guard clause in `BoardLive`
  rejects every `@write_events` event when not admin; hiding the UI
  controls is cosmetic. Notes and `approach` (per-job "way in" playbook —
  route in, story to tell, referral plan; violet panel in the admin modal)
  stay private: the read-only job modal omits both fields and filters
  `note` activities out of the render, so they never hit the wire. Dev has no proxy, so `auth_bypass: true`
  (config/dev.exs) makes `/login` grant access directly. Logout drops only
  the app session; the `.inevitable.fyi` SSO cookie survives, so the next
  login is a silent round-trip.
- **Yeet API** (`POST /api/jobs`, `JobbanWeb.Api.JobController`):
  unauthenticated-by-design endpoint that takes `{"url": ...}` (JSON or
  form), runs the importer, and drops the card into the leftmost stage.
  Idempotent on posting URL (`Board.get_job_by_url/1` → `already_tracked`).
  Guardrails for being public: `Jobban.RateLimit` (fixed-window ETS;
  5/min per IP + 30/hr global via `:yeet_rate_limits`) and an SSRF check
  in the importer (`blocked_host?/1` refuses private/loopback address
  space; config `importer_block_private_hosts`, off in test so stubs
  don't need DNS).
- **Launchpad** (`JobbanWeb.LaunchpadLive`, `/launchpad`): the private
  wishlist→applied prep view, built as **one flow, not a feature pile** — pick
  the highest-leverage way in for each company and walk through doing it, so you
  apply with an edge instead of cold. The ways in are **plays**, codified in
  `Jobban.Board.Plays` (`networking`, `pitch`, `build`, `blog`, `apply`; add one
  there and it flows through the strategist prompt, the queue's route, and task
  generation). The main view is a **priority queue** (`Board.list_launchpad/0`
  rows — every wishlist job plus applied jobs with unfinished prep, ordered by
  fit/excitement/aging); each row shows the recommended way in (`queue_route/1`:
  side door · <play> / front door / not assessed) and the single next action
  (`next_action_label/1`) with a prep meter. The detail modal is a **runway**:
  it **leads with a "Do this next" card** (`compute_next_move/1` — the single
  next action + why, from the top recommended play and its first open step;
  routes to assess / find-people / a task / done), then three ordered beats —
  **1 · Size it up** (the briefing), **2 · The plan** (the full checklist,
  always visible — `checklist_groups/1` groups every step by play with leverage
  + rationale, done steps struck-through and still uncheckable via
  `toggle_task`), and **3 · Reach out** (who to find, generated, flowing into
  your saved contacts — the old "Who to reach" and "Contacts" are now one
  section). The collapsible beats are **server-tracked** (`open_sections` MapSet
  + `toggle_section`; collapsed by default, state survives the re-render that
  fires on every in-modal mutation). **Admin-only in full** — redirects
  non-admins, since plays/contacts/prep are the strategic layer the board hides.
  Three per-job models in `Jobban.Board.*`: `JobPlay`
  (one per job×play — `leverage` high/medium/low/skip + `rationale` +
  `assessed_at`), `Task` (a prep step; steps from a recommended play carry that
  `play_slug`, freeform ones nil; `done`/`done_at`/`position`), and `Contact`
  (name/role/relationship/email/linkedin/notes + `reached_out_at`; per-job,
  shaped to later hoist into a shared people table). `Jobban.Strategist`
  (mirrors `FitScorer`: gated `strategist_enabled` + OpenRouter key,
  fire-and-forget on create + boot backfill + on-demand re-assess) makes one
  LLM call rating every play and returning steps; `Board.record_assessment/2`
  upserts the `JobPlay` rows and **regenerates** the auto-populated tasks
  (wipes machine steps, keeps freeform). Dragging a card into `applied`
  auto-checks the cold-apply play's steps inside `move_job/3` (the board move
  is source of truth). LLM is always an enhancement — an unassessed job just
  shows a "Not assessed yet · Size it up" row until assessed.
- **Networking help** (`Jobban.Networking`, the detail's "Who to reach"
  section): since the networking play is near-universally high-leverage, this
  demystifies the *who/how*. `guide/1` (on-demand) generates per-listing
  `NetworkingTarget` rows — hiring manager / recruiter / team IC / warm
  connection, each with a `title_hint` and a concrete `how_to_find` recipe
  (LinkedIn search to run, how to infer the hiring manager, etc.), persisted
  via `Board.record_networking_targets/2` (replace-on-regen). `draft/2`
  (on-demand, not persisted) drafts outreach for a target or saved contact —
  both a LinkedIn DM and an email — shown in an overlay with copy buttons.
  Same gating as the others (`networking_enabled` + key, off in test).
- **Briefing** (`Jobban.Briefing`): on-demand per-listing explainer — what the
  company does, where this role likely sits, and its strategic value. `brief/1`
  generates and upserts a `JobBrief` (has_one per job) via `Board.record_brief/2`;
  `brief_async/1` is the fire-and-forget variant (mirrors `FitScorer.score_async`).
  Surfaced in **two places**: the launchpad detail's "1 · Size it up" beat, and an
  **admin-only card in the public board's job modal** (`BoardLive`, alongside the
  way-in/fit cards, generated via `generate_brief`) — the board is the *only* place
  to brief an interviewing-stage job, since by then it has left the launchpad.
  Hidden from logged-out visitors like notes/approach. Gated `briefing_enabled` +
  key (off in test). Prep for interviews/outreach.
- **JS hooks** (`assets/js/hooks.js`): `BoardColumn` (SortableJS,
  forceFallback for styled drags), `Celebrate` (canvas-confetti),
  `AutoFocus`, `AutoDismiss` (info flashes, 2.5s), `SubmitOnMetaEnter`
  (⌘↵ submits the note textarea), `Copy` (copy `data-copy` to clipboard,
  used by the outreach-draft overlay). SortableJS + confetti are vendored in
  `assets/vendor/` — no npm.

## Conventions

- Quick-add forms re-key on `@quick_add_seq` so they reset + refocus after
  each submit (rapid entry).
- All `Board` attrs maps use **string keys** (mixing atom/string breaks
  Ecto cast).
- Tests: `Req.Test` stubs all importer HTTP (`config/test.exs` plugs
  `Jobban.Importer`); no live network in CI. LiveView async import is
  tested with `render_async/1`.
- Run `mix test` before pushing — CI gates the image build on it.

## Deploy / ops

- Push to `main` → GitHub Actions tests, builds multi-arch image to
  `ghcr.io/jhgaylor/jobban:latest` (~11 min), GitHub webhook pings Flux,
  Flux applies `k8s/` from this repo.
- Image tag is mutable `:latest` → after CI completes run
  `kubectl -n jobban rollout restart deployment/jobban`
  (`KUBECONFIG=~/.kube/config-home-cloud`).
- Secrets: `SECRET_KEY_BASE` + `OPENROUTER_API_KEY`
  live SOPS-encrypted in `k8s/jobban-secrets.enc.yaml` (cluster age key;
  `.sops.yaml` has the recipient, local key at
  `~/.config/sops/age/keys.txt` — on macOS pass
  `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`, sops doesn't look
  there by default). Edit with
  `sops k8s/jobban-secrets.enc.yaml`. DATABASE_URL comes from the
  CNPG-generated `jobban-pg-app` Secret. The OpenRouter key is shared
  with grocery-aid.
- Flux registration lives in home-cloud:
  `clusters/home/apps/jobban.yaml` + the webhook receiver entry in
  `k8s/flux-webhooks/receiver.yaml`.
- Migrations + seeds run on every container boot (`Jobban.Release`).

## Roadmap notes

- People/CRM: a first cut shipped as per-job `Contact` rows (see Launchpad).
  Still deferred: hoisting to a *global* people layer so one person can span
  jobs ("who did I talk to at X" across companies). Design sketch when that
  itch returns: global `people` table + `job_people` join with role + optional
  `activities.person_id`, backfilled from existing `contacts`. The `Contact`
  schema was kept deliberately flat to make that migration cheap.
