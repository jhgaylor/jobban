defmodule Jobban.Repo.Migrations.AddApproachToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :approach, :text
    end
  end
end
