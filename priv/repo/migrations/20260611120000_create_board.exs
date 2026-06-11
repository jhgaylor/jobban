defmodule Jobban.Repo.Migrations.CreateBoard do
  use Ecto.Migration

  def change do
    create table(:stages) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:stages, [:slug])

    create table(:jobs) do
      add :company, :string, null: false
      add :title, :string, null: false
      add :url, :string
      add :location, :string
      add :salary, :string
      add :source, :string
      add :excitement, :integer, null: false, default: 3
      add :notes, :text
      add :applied_on, :date
      add :position, :integer, null: false, default: 0
      add :stage_entered_at, :utc_datetime, null: false
      add :stage_id, references(:stages, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:jobs, [:stage_id, :position])

    create table(:activities) do
      add :kind, :string, null: false
      add :body, :text, null: false
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:activities, [:job_id])
  end
end
