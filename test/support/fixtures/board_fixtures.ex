defmodule Jobban.BoardFixtures do
  @moduledoc """
  Test helpers for creating board entities.
  """

  alias Jobban.Repo
  alias Jobban.Board
  alias Jobban.Board.Stage

  def stages_fixture do
    [
      %{name: "Wishlist", slug: "wishlist", position: 0},
      %{name: "Applied", slug: "applied", position: 1},
      %{name: "Interviewing", slug: "interviewing", position: 2},
      %{name: "Offer", slug: "offer", position: 3},
      %{name: "Rejected", slug: "rejected", position: 4}
    ]
    |> Enum.map(&Repo.insert!(Stage.changeset(%Stage{}, &1)))
  end

  def job_fixture(stage, attrs \\ %{}) do
    {:ok, job} =
      attrs
      |> Enum.into(%{
        "company" => "Acme Corp",
        "title" => "Staff Engineer",
        "stage_id" => stage.id
      })
      |> Board.create_job()

    job
  end
end
