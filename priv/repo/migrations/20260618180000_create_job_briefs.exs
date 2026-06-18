defmodule Jobban.Repo.Migrations.CreateJobBriefs do
  use Ecto.Migration

  def change do
    create table(:job_briefs) do
      add :company_overview, :text
      add :role_in_company, :text
      add :strategic_value, :text
      add :generated_at, :utc_datetime
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:job_briefs, [:job_id])
  end
end
