defmodule Jobban.Repo.Migrations.TasksSlugToPlaySlug do
  use Ecto.Migration

  # The fixed standard checklist is replaced by the plays model: each task now
  # belongs to a play (play_slug) and is regenerated from the strategist's
  # assessment. Drop the old standard-checklist rows and the slug column.
  def up do
    execute("DELETE FROM tasks WHERE slug IS NOT NULL")
    drop_if_exists index(:tasks, [:job_id, :slug], name: :tasks_job_slug_index)

    alter table(:tasks) do
      add :play_slug, :string
      remove :slug
    end

    create index(:tasks, [:job_id, :play_slug])
  end

  def down do
    drop_if_exists index(:tasks, [:job_id, :play_slug])

    alter table(:tasks) do
      add :slug, :string
      remove :play_slug
    end
  end
end
