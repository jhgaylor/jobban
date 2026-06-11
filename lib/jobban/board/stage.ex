defmodule Jobban.Board.Stage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "stages" do
    field :name, :string
    field :slug, :string
    field :position, :integer

    has_many :jobs, Jobban.Board.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:name, :slug, :position])
    |> validate_required([:name, :slug, :position])
    |> unique_constraint(:slug)
  end
end
