defmodule Jobban.Board.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A person tied to a job — the referral target, recruiter, hiring manager, or
  someone on the team. Per-job for now; the schema deliberately stays simple so
  it can later be hoisted into a shared people table + join (see roadmap notes)
  without reshaping the LiveView.
  """

  schema "contacts" do
    field :name, :string
    field :role, :string
    field :relationship, :string
    field :email, :string
    field :linkedin_url, :string
    field :notes, :string
    field :reached_out_at, :date

    belongs_to :job, Jobban.Board.Job

    timestamps(type: :utc_datetime)
  end

  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [
      :name,
      :role,
      :relationship,
      :email,
      :linkedin_url,
      :notes,
      :reached_out_at,
      :job_id
    ])
    |> validate_required([:name, :job_id])
    |> foreign_key_constraint(:job_id)
  end
end
