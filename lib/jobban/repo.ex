defmodule Jobban.Repo do
  use Ecto.Repo,
    otp_app: :jobban,
    adapter: Ecto.Adapters.Postgres
end
