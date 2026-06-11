defmodule Jobban.BoardTest do
  use Jobban.DataCase, async: true

  import Jobban.BoardFixtures

  alias Jobban.Board

  setup do
    [wishlist, applied, interviewing, offer, _rejected] = stages_fixture()
    %{wishlist: wishlist, applied: applied, interviewing: interviewing, offer: offer}
  end

  describe "create_job/1" do
    test "inserts at the top of the stage and logs an activity", %{wishlist: wishlist} do
      older = job_fixture(wishlist, %{"company" => "First"})
      newer = job_fixture(wishlist, %{"company" => "Second"})

      [stage | _] = Board.list_stages()
      assert Enum.map(stage.jobs, & &1.id) == [newer.id, older.id]

      job = Board.get_job!(newer.id)
      assert [%{kind: "created"}] = job.activities
    end

    test "requires company and title", %{wishlist: wishlist} do
      assert {:error, changeset} = Board.create_job(%{"stage_id" => wishlist.id})
      assert %{company: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects non-http urls", %{wishlist: wishlist} do
      assert {:error, changeset} =
               Board.create_job(%{
                 "stage_id" => wishlist.id,
                 "company" => "Acme",
                 "title" => "Eng",
                 "url" => "ftp://nope"
               })

      assert %{url: ["must be an http(s) link"]} = errors_on(changeset)
    end
  end

  describe "move_job/3" do
    test "moves between stages, reindexes, resets the stage timer, and logs",
         %{wishlist: wishlist, applied: applied} do
      job = job_fixture(wishlist)
      other = job_fixture(applied, %{"company" => "Other"})

      {:ok, moved} = Board.move_job(job, applied.id, 1)

      stages = Board.list_stages()
      applied_jobs = stages |> Enum.find(&(&1.id == applied.id)) |> Map.fetch!(:jobs)
      wishlist_jobs = stages |> Enum.find(&(&1.id == wishlist.id)) |> Map.fetch!(:jobs)

      assert Enum.map(applied_jobs, & &1.id) == [other.id, job.id]
      assert Enum.map(applied_jobs, & &1.position) == [0, 1]
      assert wishlist_jobs == []
      assert moved.stage_id == applied.id

      reloaded = Board.get_job!(job.id)
      assert Enum.any?(reloaded.activities, &(&1.kind == "moved"))
    end

    test "reorders within a stage without logging a move", %{wishlist: wishlist} do
      a = job_fixture(wishlist, %{"company" => "A"})
      b = job_fixture(wishlist, %{"company" => "B"})

      # column order is [b, a]; move a to the top
      {:ok, _} = Board.move_job(Board.get_job!(a.id), wishlist.id, 0)

      [stage | _] = Board.list_stages()
      assert Enum.map(stage.jobs, & &1.id) == [a.id, b.id]

      reloaded = Board.get_job!(a.id)
      refute Enum.any?(reloaded.activities, &(&1.kind == "moved"))
    end

    test "broadcasts board changes to subscribers", %{wishlist: wishlist, applied: applied} do
      job = job_fixture(wishlist)
      Board.subscribe()

      {:ok, _} = Board.move_job(job, applied.id, 0)
      assert_receive {:board_changed}
    end
  end

  describe "stats/0" do
    test "counts by stage", %{wishlist: wishlist, applied: applied, offer: offer} do
      job_fixture(wishlist)
      job_fixture(applied)
      job_fixture(applied, %{"company" => "Two"})
      job_fixture(offer)

      stats = Board.stats()
      assert stats.total == 4
      assert stats.in_flight == 2
      assert stats.offers == 1
    end
  end

  describe "add_note/2" do
    test "appends a note activity", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.add_note(job, "  Spoke to recruiter  ")

      reloaded = Board.get_job!(job.id)
      assert Enum.any?(reloaded.activities, &(&1.kind == "note" and &1.body == "Spoke to recruiter"))
    end
  end
end
