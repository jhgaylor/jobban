defmodule Jobban.LaunchpadTest do
  use Jobban.DataCase, async: true

  import Jobban.BoardFixtures

  alias Jobban.Board

  setup do
    [wishlist, applied, _interviewing, _offer, rejected] = stages_fixture()
    %{wishlist: wishlist, applied: applied, rejected: rejected}
  end

  describe "standard checklist seeding" do
    test "create_job seeds the standard readiness checklist", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      slugs = job_slugs(job.id)

      assert slugs == Enum.map(Board.standard_tasks(), &elem(&1, 0))
    end

    test "seed_standard_tasks is idempotent", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      before = length(Board.get_job!(job.id).tasks)

      Board.seed_standard_tasks(job)

      assert length(Board.get_job!(job.id).tasks) == before
    end

    test "backfill seeds only jobs that have no standard tasks", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      Repo.delete_all(Jobban.Board.Task)

      # The backfill is gated off in test config (it runs from the app's boot
      # task); flip it on just for this assertion. Nothing else reads the flag.
      Application.put_env(:jobban, :standard_task_backfill_enabled, true)
      Board.backfill_standard_tasks()
      Application.put_env(:jobban, :standard_task_backfill_enabled, false)

      assert job_slugs(job.id) == Enum.map(Board.standard_tasks(), &elem(&1, 0))
    end
  end

  describe "tasks" do
    test "add_task appends a freeform task below the checklist", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, task} = Board.add_task(job, "  Call the recruiter  ")

      assert task.title == "Call the recruiter"
      assert task.slug == nil
      assert task.position == length(Board.standard_tasks())
    end

    test "toggle_task flips done and stamps done_at", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      task = hd(Board.get_job!(job.id).tasks)

      {:ok, done} = Board.toggle_task(task)
      assert done.done and done.done_at

      {:ok, undone} = Board.toggle_task(done)
      assert not undone.done and is_nil(undone.done_at)
    end

    test "delete_task removes it", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, task} = Board.add_task(job, "scratch")

      {:ok, _} = Board.delete_task(task)
      refute Enum.any?(Board.get_job!(job.id).tasks, &(&1.id == task.id))
    end
  end

  describe "move into Applied auto-completes the apply step" do
    test "checks off the apply task on the move", %{wishlist: wishlist, applied: applied} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.move_job(job, applied.id, 0)

      apply_task = Enum.find(Board.get_job!(job.id).tasks, &(&1.slug == "apply"))
      assert apply_task.done
    end

    test "moving to a non-applied stage leaves it open", %{wishlist: wishlist, rejected: rejected} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.move_job(job, rejected.id, 0)

      apply_task = Enum.find(Board.get_job!(job.id).tasks, &(&1.slug == "apply"))
      refute apply_task.done
    end
  end

  describe "contacts" do
    test "add, toggle reached, and delete", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, contact} = Board.add_contact(job, %{"name" => "Dana", "role" => "Recruiter"})

      assert contact.name == "Dana"
      assert is_nil(contact.reached_out_at)

      {:ok, reached} = Board.toggle_contact_reached(contact)
      assert reached.reached_out_at == Date.utc_today()

      {:ok, cleared} = Board.toggle_contact_reached(reached)
      assert is_nil(cleared.reached_out_at)

      {:ok, _} = Board.delete_contact(cleared)
      assert Board.get_job!(job.id).contacts == []
    end

    test "name is required", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      assert {:error, changeset} = Board.add_contact(job, %{"role" => "Recruiter"})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_launchpad/0" do
    test "includes all wishlist jobs, ordered by fit then excitement", %{wishlist: wishlist} do
      low = job_fixture(wishlist, %{"company" => "Low", "excitement" => 2})
      high = job_fixture(wishlist, %{"company" => "High", "excitement" => 5})

      {:ok, _} = Board.record_fit(low, 2, "meh")
      {:ok, _} = Board.record_fit(high, 5, "great")

      assert [%{id: first}, %{id: second}] = Board.list_launchpad()
      assert first == high.id
      assert second == low.id
    end

    test "includes applied jobs only while prep is unfinished", %{
      wishlist: wishlist,
      applied: applied
    } do
      job = job_fixture(wishlist)
      {:ok, _} = Board.move_job(job, applied.id, 0)

      # apply step auto-completed, others still open → still on the worklist
      assert Enum.any?(Board.list_launchpad(), &(&1.id == job.id))

      # finish everything → drops off
      Board.get_job!(job.id).tasks
      |> Enum.reject(& &1.done)
      |> Enum.each(&Board.toggle_task/1)

      refute Enum.any?(Board.list_launchpad(), &(&1.id == job.id))
    end

    test "preloads tasks and contacts", %{wishlist: wishlist} do
      job = job_fixture(wishlist)
      contact_fixture(job)

      [loaded] = Board.list_launchpad()
      assert length(loaded.tasks) == length(Board.standard_tasks())
      assert [%{name: "Dana Recruiter"}] = loaded.contacts
    end
  end

  defp job_slugs(job_id) do
    Board.get_job!(job_id).tasks
    |> Enum.filter(& &1.slug)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.slug)
  end
end
