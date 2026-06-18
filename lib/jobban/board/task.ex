defmodule Jobban.Board.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A prep step for a job. Steps generated from a recommended play carry that
  play's `play_slug`; freeform steps the user adds by hand have a nil play_slug.
  `done`/`done_at` track completion.
  """

  schema "tasks" do
    field :play_slug, :string
    field :title, :string
    field :done, :boolean, default: false
    field :done_at, :utc_datetime
    field :position, :integer, default: 0

    belongs_to :job, Jobban.Board.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:play_slug, :title, :done, :done_at, :position, :job_id])
    |> validate_required([:title, :job_id])
    |> foreign_key_constraint(:job_id)
  end
end
