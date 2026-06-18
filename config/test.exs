import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :jobban, Jobban.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "jobban_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :jobban, JobbanWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "X5spSCv2e8zBy8TcbL4swSnefzy2lZ5EHioyuhD0Xz8loBq2BG/J+wWjr+yKUSaB",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Route importer HTTP through Req.Test stubs (no live network in tests)
config :jobban, importer_req_options: [plug: {Req.Test, Jobban.Importer}]

# Fit scoring: off by default so creates stay deterministic; FitScorer tests
# call score/1 directly through the OpenRouter stub with an inline profile
config :jobban,
  fit_scoring_enabled: false,
  strategist_enabled: false,
  networking_enabled: false,
  briefing_enabled: false,
  fit_profile: "Test candidate: staff platform engineer, remote only.",
  openrouter_req_options: [plug: {Req.Test, Jobban.LLM.OpenRouter}]

# Auth: GitHub login the proxy header must match
config :jobban, github_user: "jhgaylor"

# API yeet endpoint: tiny per-ip limit so tests can hit it deterministically;
# host blocking off so importer stubs don't need DNS
config :jobban,
  yeet_rate_limits: [per_ip: {2, 60_000}, global: {100_000, 3_600_000}],
  importer_block_private_hosts: false
