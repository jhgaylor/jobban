defmodule Jobban.Board.JobPlay do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  The strategist's assessment of one play for one job: how much leverage it
  carries (`high`/`medium`/`low`/`skip`) and why. The recommended ones drive
  task generation; all of them paint the Launchpad matrix.
  """

  alias Jobban.Board.Plays

  schema "job_plays" do
    field :slug, :string
    field :leverage, :string
    field :rationale, :string
    field :assessed_at, :utc_datetime

    belongs_to :job, Jobban.Board.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(job_play, attrs) do
    job_play
    |> cast(attrs, [:slug, :leverage, :rationale, :assessed_at, :job_id])
    |> validate_required([:slug, :job_id])
    |> validate_inclusion(:slug, Plays.slugs())
    |> validate_inclusion(:leverage, Plays.leverages())
    |> foreign_key_constraint(:job_id)
    |> unique_constraint([:job_id, :slug])
  end
end
