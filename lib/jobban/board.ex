defmodule Jobban.Board do
  @moduledoc """
  The job-search board: stages, jobs, and per-job activity history.

  Every mutation broadcasts `{:board_changed}` on the "board" topic so all
  connected LiveViews stay in sync.
  """

  import Ecto.Query, warn: false

  alias Jobban.Repo
  alias Jobban.Board.{Activity, Job, Stage}

  @topic "board"

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
    Repo.preload(job, [:stage, activities: activities_query])
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
          job
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    with {:ok, job} <- result do
      broadcast_change()
      {:ok, job}
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
