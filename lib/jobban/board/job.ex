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

    belongs_to :stage, Jobban.Board.Stage
    has_many :activities, Jobban.Board.Activity

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

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.new(value) do
        {:ok, %URI{scheme: scheme}} when scheme in ["http", "https"] -> []
        _ -> [{field, "must be an http(s) link"}]
      end
    end)
  end
end
