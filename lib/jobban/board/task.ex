defmodule Jobban.Board.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A prep step for a job. Standard readiness-checklist items carry a `slug`
  (seeded per job from `Jobban.Board.standard_tasks/0`); freeform tasks have a
  nil slug. `done`/`done_at` track completion.
  """

  schema "tasks" do
    field :slug, :string
    field :title, :string
    field :done, :boolean, default: false
    field :done_at, :utc_datetime
    field :position, :integer, default: 0

    belongs_to :job, Jobban.Board.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:slug, :title, :done, :done_at, :position, :job_id])
    |> validate_required([:title, :job_id])
    |> foreign_key_constraint(:job_id)
  end
end
