# jobban — project context

Job-search kanban for Jake (jhgaylor). Phoenix LiveView 1.8, single-user,
deployed on the home-cloud k3s cluster at https://jobban.inevitable.fyi
behind GitHub SSO. Generic Phoenix/LiveView guidance lives in @AGENTS.md;
this file is the project-specific context.

## Architecture (and why)

- **One LiveView** (`JobbanWeb.BoardLive`) renders the whole board. All
  mutations go through the `Jobban.Board` context, which broadcasts
  `{:board_changed}` on the `"board"` PubSub topic; every connected view
  reloads. Coarse-grained on purpose — a personal board is small, and
  "reload everything" keeps move/reindex logic trivially correct.
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
- **JS hooks** (`assets/js/hooks.js`): `BoardColumn` (SortableJS,
  forceFallback for styled drags), `Celebrate` (canvas-confetti),
  `AutoFocus`, `AutoDismiss` (info flashes, 2.5s), `SubmitOnMetaEnter`
  (⌘↵ submits the note textarea). SortableJS + confetti are vendored in
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
- Secrets: `SECRET_KEY_BASE` + `OPENROUTER_API_KEY` live SOPS-encrypted in
  `k8s/jobban-secrets.enc.yaml` (cluster age key; `.sops.yaml` has the
  recipient, local key at `~/.config/sops/age/keys.txt`). Edit with
  `sops k8s/jobban-secrets.enc.yaml`. DATABASE_URL comes from the
  CNPG-generated `jobban-pg-app` Secret. The OpenRouter key is shared
  with grocery-aid.
- Flux registration lives in home-cloud:
  `clusters/home/apps/jobban.yaml` + the webhook receiver entry in
  `k8s/flux-webhooks/receiver.yaml`.
- Migrations + seeds run on every container boot (`Jobban.Release`).

## Roadmap notes

- Considered and deliberately deferred: a people/CRM layer (contacts
  linked to jobs, notes taggable to a person). Design sketch: global
  `people` table + `job_people` join with role + optional
  `activities.person_id`. Revisit if Jake asks "who did I talk to at X".
