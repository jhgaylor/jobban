defmodule Jobban.Repo.Migrations.AddSearchesToNetworkingTargets do
  use Ecto.Migration

  def change do
    alter table(:networking_targets) do
      # Per-target ready-to-run searches: a list of %{"query", "platform"} maps
      # (jsonb[]). LLM-generated, read-only, replaced on regen with the target.
      add :searches, {:array, :map}, default: []
    end
  end
end
