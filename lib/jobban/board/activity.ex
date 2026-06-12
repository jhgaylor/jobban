defmodule Jobban.Board.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "activities" do
    field :kind, :string
    field :body, :string

    belongs_to :job, Jobban.Board.Job

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:kind, :body, :job_id])
    |> validate_required([:kind, :body, :job_id])
    |> validate_inclusion(:kind, ~w(created moved note updated scored))
  end
end
