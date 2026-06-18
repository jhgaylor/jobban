defmodule Jobban.LaunchpadTest do
  use Jobban.DataCase, async: true

  import Jobban.BoardFixtures

  alias Jobban.Board
  alias Jobban.Board.{JobPlay, Task}

  setup do
    [wishlist, applied, _interviewing, _offer, rejected] = stages_fixture()
    %{wishlist: wishlist, applied: applied, rejected: rejected}
  end

  defp assessment(slug, leverage, steps \\ []) do
    %{slug: slug, leverage: leverage, rationale: "because #{slug}", steps: steps}
  end

  describe "record_assessment/2" do
    test "stores play leverage and auto-populates recommended plays' steps", %{wishlist: wishlist} do
      job = job_fixture(wishlist)

      {:ok, _} =
        Board.record_assessment(job, [
          assessment("networking", "high", ["Ask Dana for an intro", "DM the hiring manager"]),
          assessment("build", "medium", ["Ship a small demo"]),
          assessment("blog", "skip"),
          assessment("apply", "low", ["Submit the application"])
        ])

      reloaded = Board.get_job!(job.id)

      leverages = Map.new(reloaded.job_plays, &{&1.slug, &1.leverage})

      assert leverages == %{
               "networking" => "high",
               "build" => "medium",
               "blog" => "skip",
               "apply" => "low"
             }

      # steps generated only for non-skip plays
      titles = Enum.map(reloaded.tasks, & &1.title)
      assert "Ask Dana for an intro" in titles
      assert "Ship a small demo" in titles
      refute Enum.any?(reloaded.tasks, &(&1.play_slug == "blog"))
      assert Enum.find(reloaded.tasks, &(&1.title == "Ship a small demo")).play_slug == "build"
    end

    test "re-assessing replaces machine steps but keeps freeform ones", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("networking", "high", ["Old step"])])
      {:ok, _} = Board.add_task(job, "My own step")

      {:ok, _} = Board.record_assessment(job, [assessment("networking", "high", ["New step"])])

      titles = Board.get_job!(job.id).tasks |> Enum.map(& &1.title)
      assert "New step" in titles
      refute "Old step" in titles
      assert "My own step" in titles
    end

    test "ignores plays outside the catalog", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("bribery", "high", ["nope"])])

      assert Board.get_job!(job.id).job_plays == []
    end

    test "assessing a deleted job is a clean no-op", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.delete_job(Board.get_job!(job.id))

      assert {:error, :job_deleted} = Board.record_assessment(job, [assessment("apply", "low")])
    end

    test "broadcasts the change", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      Board.subscribe()
      {:ok, _} = Board.record_assessment(job, [assessment("apply", "low", ["go"])])
      assert_receive {:board_changed}
    end
  end

  describe "jobs_missing_assessment/0" do
    test "returns only jobs with no play assessment", %{wishlist: wishlist} do
      assessed = job_fixture(wishlist, %{"company" => "A"})
      unassessed = job_fixture(wishlist, %{"company" => "B"})
      {:ok, _} = Board.record_assessment(assessed, [assessment("apply", "low")])

      ids = Enum.map(Board.jobs_missing_assessment(), & &1.id)
      assert unassessed.id in ids
      refute assessed.id in ids
    end
  end

  describe "move into Applied auto-completes the cold-apply play" do
    test "checks off the apply play's steps on the move", %{wishlist: wishlist, applied: applied} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("apply", "high", ["Submit it"])])

      {:ok, _} = Board.move_job(Board.get_job!(job.id), applied.id, 0)

      apply_tasks = Board.get_job!(job.id).tasks |> Enum.filter(&(&1.play_slug == "apply"))
      assert apply_tasks != []
      assert Enum.all?(apply_tasks, & &1.done)
    end
  end

  describe "tasks" do
    test "add_task appends a freeform (play-less) step", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, task} = Board.add_task(job, "  Call the recruiter  ")

      assert task.title == "Call the recruiter"
      assert task.play_slug == nil
    end

    test "toggle and delete", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, task} = Board.add_task(job, "scratch")

      {:ok, done} = Board.toggle_task(task)
      assert done.done and done.done_at

      {:ok, _} = Board.delete_task(done)
      assert Board.get_job!(job.id).tasks == []
    end
  end

  describe "contacts" do
    test "add, toggle reached, delete", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, contact} = Board.add_contact(job, %{"name" => "Dana", "role" => "Recruiter"})
      assert is_nil(contact.reached_out_at)

      {:ok, reached} = Board.toggle_contact_reached(contact)
      assert reached.reached_out_at == Date.utc_today()

      {:ok, _} = Board.delete_contact(reached)
      assert Board.get_job!(job.id).contacts == []
    end

    test "name is required", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      assert {:error, changeset} = Board.add_contact(job, %{"role" => "Recruiter"})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_launchpad/0" do
    test "includes wishlist jobs ordered by fit then excitement, with plays preloaded", %{
      wishlist: wishlist
    } do
      low = job_fixture(wishlist, %{"company" => "Low", "excitement" => 2})
      high = job_fixture(wishlist, %{"company" => "High", "excitement" => 5})
      {:ok, _} = Board.record_fit(low, 2, "meh")
      {:ok, _} = Board.record_fit(high, 5, "great")
      {:ok, _} = Board.record_assessment(high, [assessment("networking", "high", ["intro"])])

      assert [first, second] = Board.list_launchpad()
      assert first.id == high.id
      assert second.id == low.id
      assert [%JobPlay{slug: "networking"}] = first.job_plays
    end

    test "drops applied jobs once their checklist is finished", %{
      wishlist: wishlist,
      applied: applied
    } do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("networking", "high", ["do it"])])
      {:ok, _} = Board.move_job(Board.get_job!(job.id), applied.id, 0)

      assert Enum.any?(Board.list_launchpad(), &(&1.id == job.id))

      Board.get_job!(job.id).tasks
      |> Enum.reject(& &1.done)
      |> Enum.each(&Board.toggle_task/1)

      refute Enum.any?(Board.list_launchpad(), &(&1.id == job.id))
    end
  end

  test "creating a job leaves it unassessed (strategist disabled in test)", %{wishlist: wishlist} do
    job = job_fixture(wishlist)
    assert Repo.all(from p in JobPlay, where: p.job_id == ^job.id) == []
    assert Repo.all(from t in Task, where: t.job_id == ^job.id) == []
  end
end
