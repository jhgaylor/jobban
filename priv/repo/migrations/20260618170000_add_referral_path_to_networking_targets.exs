defmodule Jobban.Repo.Migrations.AddReferralPathToNetworkingTargets do
  use Ecto.Migration

  def change do
    alter table(:networking_targets) do
      # What to get from this contact and how to convert it into a referral.
      add :referral_path, :text
    end
  end
end
