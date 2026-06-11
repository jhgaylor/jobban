defmodule Jobban.Release do
  @moduledoc """
  Release-time tasks invoked from `bin/jobban eval ...` inside the
  container. Mix is not present in releases, so anything that would
  normally run via `mix ecto.migrate` / `mix run priv/repo/seeds.exs`
  lives here.
  """
  @app :jobban

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Runs the (idempotent) stage seeds. Safe to call on every boot.
  """
  def seed do
    load_app()

    seeds = Path.join([:code.priv_dir(@app), "repo", "seeds.exs"])

    if File.exists?(seeds) do
      for repo <- repos() do
        {:ok, _, _} =
          Ecto.Migrator.with_repo(repo, fn _repo -> Code.eval_file(seeds) end)
      end
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
