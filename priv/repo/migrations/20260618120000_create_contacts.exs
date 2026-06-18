defmodule Jobban.Repo.Migrations.CreateContacts do
  use Ecto.Migration

  def change do
    create table(:contacts) do
      add :name, :string, null: false
      add :role, :string
      add :relationship, :string
      add :email, :string
      add :linkedin_url, :string
      add :notes, :text
      add :reached_out_at, :date
      add :job_id, references(:jobs, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:contacts, [:job_id])
  end
end
