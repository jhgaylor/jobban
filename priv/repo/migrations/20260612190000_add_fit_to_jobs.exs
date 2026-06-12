defmodule Jobban.Repo.Migrations.AddFitToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :fit_score, :integer
      add :fit_summary, :text
      add :fit_scored_at, :utc_datetime
    end
  end
end
