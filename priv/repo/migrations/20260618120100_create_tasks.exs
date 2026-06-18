defmodule Jobban.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      # slug is set for the standard readiness checklist (way_in, referral, …)
      # and null for freeform tasks; it's what keeps seeding idempotent.
      add :slug, :string
      add :title, :string, null: false
      add :done, :boolean, null: false, default: false
      add :done_at, :utc_datetime
      add :position, :integer, null: false, default: 0
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:job_id, :position])

    create unique_index(:tasks, [:job_id, :slug],
             where: "slug IS NOT NULL",
             name: :tasks_job_slug_index
           )
  end
end
