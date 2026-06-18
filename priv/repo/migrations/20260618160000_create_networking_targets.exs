defmodule Jobban.Repo.Migrations.CreateNetworkingTargets do
  use Ecto.Migration

  def change do
    create table(:networking_targets) do
      add :label, :string, null: false
      add :title_hint, :string
      add :why, :text
      add :how_to_find, :text
      add :position, :integer, null: false, default: 0
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:networking_targets, [:job_id, :position])
  end
end
