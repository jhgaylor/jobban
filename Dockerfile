# syntax=docker/dockerfile:1.7
#
# Phoenix release image for jobban. Multi-stage: a build stage compiles
# assets + the Elixir release against Erlang/OTP 28 + Elixir 1.19, and a
# slim Debian runtime stage carries only the release.
#
# Mirrors the home-cloud convention used by grocery-aid (single-replica
# deploy; SECRET_KEY_BASE + DATABASE_URL supplied via env at runtime).

FROM hexpm/elixir:1.19.5-erlang-28.1.1-debian-bookworm-20260505-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod \
 && mix deps.compile

COPY config ./config
COPY assets ./assets
COPY priv ./priv
COPY lib ./lib

# Compile first so Phoenix 1.8 colocated LiveView JS hooks are written to
# the build path (esbuild's NODE_PATH) before assets.deploy bundles them.
RUN mix compile

# Build + digest static assets (tailwind + esbuild) into priv/static.
RUN mix assets.setup \
 && mix assets.deploy

RUN mix release

# ---

FROM debian:bookworm-slim AS runtime

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    PHX_HOST=jobban.inevitable.fyi

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/_build/prod/rel/jobban ./

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--"]
# SECRET_KEY_BASE and DATABASE_URL must be supplied via environment
# (k8s Secret + CNPG-generated Secret). Migrate + seed run on boot.
CMD ["/bin/sh", "-c", "/app/bin/jobban eval 'Jobban.Release.migrate()' && /app/bin/jobban eval 'Jobban.Release.seed()' && exec /app/bin/jobban start"]
