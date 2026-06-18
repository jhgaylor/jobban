defmodule Jobban.Board do
  @moduledoc """
  The job-search board: stages, jobs, and per-job activity history.

  Every mutation broadcasts `{:board_changed}` on the "board" topic so all
  connected LiveViews stay in sync.
  """

  import Ecto.Query, warn: false

  alias Jobban.Repo
  alias Jobban.Board.{Activity, Contact, Job, Stage, Task}

  @topic "board"

  # The standard wishlist→applied readiness checklist, seeded per job. Slugs
  # are stable identifiers (used for idempotent seeding and the move-to-applied
  # auto-complete); order here is the order they're shown and worked.
  @standard_tasks [
    {"way_in", "Write the way-in — route, story, referral plan"},
    {"research", "Research the company & role"},
    {"referral", "Find or ask for a referral"},
    {"resume", "Tailor your resume & materials"},
    {"apply", "Submit the application"}
  ]

  @doc "The standard readiness checklist as `{slug, title}` pairs."
  def standard_tasks, do: @standard_tasks

  def subscribe do
    Phoenix.PubSub.subscribe(Jobban.PubSub, @topic)
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(Jobban.PubSub, @topic, {:board_changed})
  end

  ## Stages

  def list_stages do
    jobs_query = from j in Job, order_by: [asc: j.position, asc: j.id]

    Stage
    |> order_by([s], asc: s.position)
    |> preload(jobs: ^jobs_query)
    |> Repo.all()
  end

  def get_stage!(id), do: Repo.get!(Stage, id)

  @doc "The leftmost stage (wishlist) — default landing column for API imports."
  def first_stage do
    Repo.one!(from s in Stage, order_by: [asc: s.position], limit: 1)
  end

  ## Jobs

  def get_job!(id) do
    Job
    |> Repo.get!(id)
    |> preload_job()
  end

  @doc "Like `get_job!/1` but returns nil when the job no longer exists."
  def get_job(id) do
    case Repo.get(Job, id) do
      nil -> nil
      job -> preload_job(job)
    end
  end

  defp preload_job(job) do
    activities_query = from a in Activity, order_by: [desc: a.inserted_at, desc: a.id]
    tasks_query = from t in Task, order_by: [asc: t.position, asc: t.id]
    contacts_query = from c in Contact, order_by: [asc: c.id]

    Repo.preload(job,
      stage: [],
      activities: activities_query,
      tasks: tasks_query,
      contacts: contacts_query
    )
  end

  @doc "Finds a job by its posting URL — keeps API imports idempotent."
  def get_job_by_url(url) when is_binary(url) do
    Repo.one(from j in Job, where: j.url == ^url, limit: 1)
  end

  def change_job(%Job{} = job, attrs \\ %{}), do: Job.changeset(job, attrs)

  @doc "Creates a job at the top of its stage's column."
  def create_job(attrs) do
    now = DateTime.utc_now(:second)

    result =
      Repo.transaction(fn ->
        changeset =
          %Job{stage_entered_at: now}
          |> Job.changeset(attrs)

        with {:ok, job} <- Repo.insert(changeset) do
          reindex_stage(job.stage_id, [job.id | stage_job_ids(job.stage_id) -- [job.id]])
          log(job, "created", "Added #{job.title} at #{job.company}")
          seed_standard_tasks(job)
          job
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    with {:ok, job} <- result do
      broadcast_change()
      Jobban.FitScorer.score_async(job)
      {:ok, job}
    end
  end

  @doc "Jobs that have never been fit-scored — the boot backfill's worklist."
  def jobs_missing_fit do
    Repo.all(from j in Job, where: is_nil(j.fit_score), order_by: [asc: j.id])
  end

  @doc """
  Records an LLM fit evaluation. Re-fetches the job by id so a job deleted
  while its scoring task was in flight is a clean no-op instead of a stale
  update.
  """
  def record_fit(%Job{id: id}, score, summary) do
    case Repo.get(Job, id) do
      nil ->
        {:error, :job_deleted}

      job ->
        attrs = %{
          fit_score: score,
          fit_summary: summary,
          fit_scored_at: DateTime.utc_now(:second)
        }

        with {:ok, job} <- job |> Job.fit_changeset(attrs) |> Repo.update() do
          log(job, "scored", "Fit check: #{score}/5#{if summary, do: " — #{summary}"}")
          broadcast_change()
          {:ok, job}
        end
    end
  end

  def update_job(%Job{} = job, attrs) do
    with {:ok, job} <- job |> Job.changeset(attrs) |> Repo.update() do
      broadcast_change()
      {:ok, job}
    end
  end

  def delete_job(%Job{} = job) do
    with {:ok, job} <- Repo.delete(job) do
      broadcast_change()
      {:ok, job}
    end
  end

  @doc """
  Moves a job to `to_stage_id` at `to_index` within that column, reindexing
  both affected columns. Logs an activity and resets the stage timer when the
  job changes stage.
  """
  def move_job(%Job{} = job, to_stage_id, to_index) do
    from_stage_id = job.stage_id

    {:ok, moved} =
      Repo.transaction(fn ->
        target_ids = List.insert_at(stage_job_ids(to_stage_id) -- [job.id], to_index, job.id)
        reindex_stage(to_stage_id, target_ids)

        if from_stage_id != to_stage_id do
          reindex_stage(from_stage_id, stage_job_ids(from_stage_id) -- [job.id])

          from(j in Job, where: j.id == ^job.id)
          |> Repo.update_all(set: [stage_entered_at: DateTime.utc_now(:second)])

          from_stage = Repo.get!(Stage, from_stage_id)
          to_stage = Repo.get!(Stage, to_stage_id)
          log(job, "moved", "Moved from #{from_stage.name} to #{to_stage.name}")

          # Dragging a card into Applied checks off the "submit application"
          # step automatically — the board move is the source of truth.
          if to_stage.slug == "applied", do: complete_standard_task(job.id, "apply")
        end

        Repo.get!(Job, job.id)
      end)

    broadcast_change()
    {:ok, moved}
  end

  def add_note(%Job{} = job, body) when is_binary(body) do
    case log(job, "note", String.trim(body)) do
      {:ok, activity} ->
        broadcast_change()
        {:ok, activity}

      error ->
        error
    end
  end

  ## Launchpad — the wishlist→applied prep view

  @doc """
  Jobs that still need prep work, prioritized. Includes every wishlist job plus
  any applied job whose readiness checklist isn't finished yet (the
  still-needs-follow-up tail). Ordered by fit, then excitement, then most-aged
  first. Tasks and contacts are preloaded.
  """
  def list_launchpad do
    tasks_query = from t in Task, order_by: [asc: t.position, asc: t.id]
    contacts_query = from c in Contact, order_by: [asc: c.id]

    from(j in Job,
      join: s in assoc(j, :stage),
      where: s.slug in ["wishlist", "applied"],
      preload: [stage: s, tasks: ^tasks_query, contacts: ^contacts_query]
    )
    |> Repo.all()
    |> Enum.filter(fn job ->
      job.stage.slug == "wishlist" or Enum.any?(job.tasks, &(not &1.done))
    end)
    |> Enum.sort_by(&launchpad_sort_key/1)
  end

  defp launchpad_sort_key(job) do
    {-(job.fit_score || 0), -(job.excitement || 0), DateTime.to_unix(job.stage_entered_at)}
  end

  ## Contacts

  def get_contact!(id), do: Repo.get!(Contact, id)

  def change_contact(%Contact{} = contact, attrs \\ %{}), do: Contact.changeset(contact, attrs)

  def add_contact(%Job{id: job_id}, attrs) do
    attrs = Map.put(attrs, "job_id", job_id)

    with {:ok, contact} <- %Contact{} |> Contact.changeset(attrs) |> Repo.insert() do
      broadcast_change()
      {:ok, contact}
    end
  end

  def update_contact(%Contact{} = contact, attrs) do
    with {:ok, contact} <- contact |> Contact.changeset(attrs) |> Repo.update() do
      broadcast_change()
      {:ok, contact}
    end
  end

  @doc "Toggles whether we've reached out to a contact (stamps/clears the date)."
  def toggle_contact_reached(%Contact{reached_out_at: nil} = contact) do
    set_contact_reached(contact, Date.utc_today())
  end

  def toggle_contact_reached(%Contact{} = contact), do: set_contact_reached(contact, nil)

  defp set_contact_reached(contact, value) do
    with {:ok, contact} <-
           contact |> Ecto.Changeset.change(reached_out_at: value) |> Repo.update() do
      broadcast_change()
      {:ok, contact}
    end
  end

  def delete_contact(%Contact{} = contact) do
    with {:ok, contact} <- Repo.delete(contact) do
      broadcast_change()
      {:ok, contact}
    end
  end

  ## Tasks

  def get_task!(id), do: Repo.get!(Task, id)

  @doc "Adds a freeform task to the bottom of a job's checklist."
  def add_task(%Job{id: job_id}, title) when is_binary(title) do
    attrs = %{
      "job_id" => job_id,
      "title" => String.trim(title),
      "position" => next_task_position(job_id)
    }

    with {:ok, task} <- %Task{} |> Task.changeset(attrs) |> Repo.insert() do
      broadcast_change()
      {:ok, task}
    end
  end

  @doc "Flips a task's done state, stamping/clearing `done_at`."
  def toggle_task(%Task{done: done} = task) do
    changes =
      if done,
        do: [done: false, done_at: nil],
        else: [done: true, done_at: DateTime.utc_now(:second)]

    with {:ok, task} <- task |> Ecto.Changeset.change(changes) |> Repo.update() do
      broadcast_change()
      {:ok, task}
    end
  end

  def delete_task(%Task{} = task) do
    with {:ok, task} <- Repo.delete(task) do
      broadcast_change()
      {:ok, task}
    end
  end

  @doc """
  Inserts any missing standard checklist items for a job. Idempotent — skips
  slugs already present — so it's safe to call on create and on backfill.
  Does not broadcast on its own; callers that mutate around it do.
  """
  def seed_standard_tasks(%Job{id: job_id} = job) do
    existing =
      Repo.all(from t in Task, where: t.job_id == ^job_id and not is_nil(t.slug), select: t.slug)

    base = next_task_position(job_id)

    @standard_tasks
    |> Enum.reject(fn {slug, _title} -> slug in existing end)
    |> Enum.with_index(base)
    |> Enum.each(fn {{slug, title}, position} ->
      %Task{}
      |> Task.changeset(%{
        "job_id" => job_id,
        "slug" => slug,
        "title" => title,
        "position" => position
      })
      |> Repo.insert!()
    end)

    job
  end

  @doc """
  Boot-time backfill: seeds the standard checklist onto jobs that predate it.
  Gated off in test so the sandbox isn't touched from the app's boot task.
  """
  def backfill_standard_tasks do
    if Application.get_env(:jobban, :standard_task_backfill_enabled, true) do
      seeded =
        Repo.all(from t in Task, where: not is_nil(t.slug), select: t.job_id, distinct: true)

      from(j in Job, where: j.id not in ^seeded)
      |> Repo.all()
      |> Enum.each(&seed_standard_tasks/1)
    end

    :ok
  end

  defp next_task_position(job_id) do
    (Repo.one(from t in Task, where: t.job_id == ^job_id, select: max(t.position)) || -1) + 1
  end

  defp complete_standard_task(job_id, slug) do
    from(t in Task, where: t.job_id == ^job_id and t.slug == ^slug and t.done == false)
    |> Repo.update_all(set: [done: true, done_at: DateTime.utc_now(:second)])
  end

  ## Stats

  @doc """
  Board-level stats keyed by stage slug, plus totals for the header.
  """
  def stats do
    counts =
      from(j in Job,
        join: s in assoc(j, :stage),
        group_by: s.slug,
        select: {s.slug, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    total = counts |> Map.values() |> Enum.sum()
    in_flight = Map.get(counts, "applied", 0) + Map.get(counts, "interviewing", 0)

    %{
      total: total,
      in_flight: in_flight,
      interviewing: Map.get(counts, "interviewing", 0),
      offers: Map.get(counts, "offer", 0),
      by_stage: counts
    }
  end

  ## Internals

  defp stage_job_ids(stage_id) do
    from(j in Job,
      where: j.stage_id == ^stage_id,
      order_by: [asc: j.position, asc: j.id],
      select: j.id
    )
    |> Repo.all()
  end

  defp reindex_stage(stage_id, ordered_ids) do
    ordered_ids
    |> Enum.with_index()
    |> Enum.each(fn {id, index} ->
      from(j in Job, where: j.id == ^id)
      |> Repo.update_all(set: [position: index, stage_id: stage_id])
    end)
  end

  defp log(%Job{id: job_id}, kind, body) do
    %Activity{}
    |> Activity.changeset(%{job_id: job_id, kind: kind, body: body})
    |> Repo.insert()
  end
end
