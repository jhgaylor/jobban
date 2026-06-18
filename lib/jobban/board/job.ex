defmodule Jobban.Board.Job do
  use Ecto.Schema
  import Ecto.Changeset

  schema "jobs" do
    field :company, :string
    field :title, :string
    field :url, :string
    field :location, :string
    field :salary, :string
    field :source, :string
    field :excitement, :integer, default: 3
    field :notes, :string
    field :approach, :string
    field :applied_on, :date
    field :position, :integer, default: 0
    field :stage_entered_at, :utc_datetime
    field :fit_score, :integer
    field :fit_summary, :string
    field :fit_scored_at, :utc_datetime

    belongs_to :stage, Jobban.Board.Stage
    has_many :activities, Jobban.Board.Activity
    has_many :contacts, Jobban.Board.Contact
    has_many :tasks, Jobban.Board.Task
    has_many :job_plays, Jobban.Board.JobPlay

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :company,
      :title,
      :url,
      :location,
      :salary,
      :source,
      :excitement,
      :notes,
      :approach,
      :applied_on,
      :stage_id
    ])
    |> validate_required([:company, :title])
    |> validate_number(:excitement, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_url(:url)
    |> foreign_key_constraint(:stage_id)
  end

  # Fit fields are written only by the scorer, never cast from user input —
  # the main changeset above deliberately leaves them out.
  def fit_changeset(job, attrs) do
    job
    |> cast(attrs, [:fit_score, :fit_summary, :fit_scored_at])
    |> validate_required([:fit_score, :fit_scored_at])
    |> validate_number(:fit_score, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] -> []
        _ -> [{field, "must be an http(s) link"}]
      end
    end)
  end
end
