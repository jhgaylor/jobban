defmodule Jobban.Repo.Migrations.CreateJobPlays do
  use Ecto.Migration

  def change do
    create table(:job_plays) do
      add :slug, :string, null: false
      add :leverage, :string
      add :rationale, :text
      add :assessed_at, :utc_datetime
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:job_plays, [:job_id, :slug])
  end
end
