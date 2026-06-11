# jobban

A kanban board purpose-built for a job search. Wishlist → Applied →
Interviewing → Offer (→ Rejected), one drag at a time — with confetti when
a card lands in Offer.

Built with Phoenix LiveView: every mutation broadcasts over PubSub, so the
board stays live across tabs and devices with no refresh.

## Features

- **Five job-search stages** seeded on boot; cards carry company, role,
  posting URL, location, salary, source, excitement (1–5 stars), and notes
- **Drag-and-drop** between and within columns (SortableJS + LiveView hook)
- **Quick-add** straight into any column, optimized for rapid entry
- **Activity timeline** per job: stage moves are logged automatically,
  notes are one keystroke away
- **Days-in-stage aging** — cards quietly turn amber after 3 days and red
  after 7 so follow-ups don't rot
- **Stats header** — tracked / in flight / interviewing / offers
- **Confetti** when a card enters Offer. Non-negotiable.
- Light/dark/system theme

## Development

Requires Elixir ~> 1.15, Erlang/OTP 28, and a local Postgres
(`postgres:postgres@localhost`).

```bash
mix setup        # deps, db create+migrate, seed stages, build assets
mix phx.server   # http://localhost:4000
mix test
```

## Deployment

Deployed to the [home-cloud](https://github.com/jhgaylor/home-cloud) k3s
cluster at `jobban.inevitable.fyi`, gated behind GitHub SSO (oauth2-proxy).

- Push to `main` → GitHub Actions runs tests, then builds a multi-arch
  (amd64+arm64) image to `ghcr.io/jhgaylor/jobban`
- Flux watches this repo and applies `k8s/` (Deployment, CNPG Postgres,
  Traefik IngressRoute, cert-manager Certificate)
- `SECRET_KEY_BASE` is SOPS-encrypted in `k8s/jobban-secrets.enc.yaml`,
  decrypted in-cluster by Flux; `DATABASE_URL` comes from the CNPG-generated
  `jobban-pg-app` Secret
- Migrations + idempotent stage seeds run on container boot
