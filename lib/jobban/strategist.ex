defmodule Jobban.Strategist do
  @moduledoc """
  LLM "way in" strategist: for a listing it rates every play in
  `Jobban.Board.Plays` for leverage (high/medium/low/skip) with a one-line
  rationale, and for the worthwhile ones spells out the specific steps to take
  for that company. `Jobban.Board.record_assessment/2` turns the recommended
  plays' steps into the auto-populated checklist.

  Same contract as the importer and fit scorer: fire-and-forget after create,
  a boot-time backfill for unassessed jobs, and an on-demand re-assess from the
  Launchpad. Any failure leaves the job unassessed and never blocks anything.

  A successful interactive assessment **fans out**: it kicks the briefing
  (`Jobban.Briefing`) and, when networking is a recommended play and unmapped,
  the people-map (`Jobban.Networking`) — both fire-and-forget, so opening a
  freshly-assessed listing already has its context filling in. The boot backfill
  skips the fan-out (`compose: false`) to avoid an LLM burst on startup.
  """

  require Logger

  alias Jobban.Board
  alias Jobban.Board.{Job, Plays}
  alias Jobban.Briefing
  alias Jobban.Importer
  alias Jobban.LLM.OpenRouter
  alias Jobban.Networking

  @doc """
  True when assessment can run: an OpenRouter key is present and the feature
  isn't disabled (it's off in test so creates stay deterministic).
  """
  def enabled? do
    Application.get_env(:jobban, :strategist_enabled, true) and OpenRouter.configured?()
  end

  @doc "Fire-and-forget assessment of one job. No-op when disabled."
  def assess_async(%Job{} = job) do
    if enabled?() do
      Task.Supervisor.start_child(Jobban.TaskSupervisor, fn -> assess(job) end)
    end

    :ok
  end

  @doc """
  Boot-time backfill: assesses every job with no play assessment yet, serially
  with a pause between calls so a large board doesn't burst-hit OpenRouter.
  """
  def backfill do
    if enabled?() do
      Process.sleep(boot_delay_ms())
      jobs = Board.jobs_missing_assessment()

      if jobs != [] do
        Logger.info("Strategist: backfilling #{length(jobs)} unassessed job(s)")
      end

      Enum.each(jobs, fn job ->
        assess(job, compose: false)
        Process.sleep(between_jobs_ms())
      end)
    end

    :ok
  end

  @doc """
  Assesses one job synchronously: asks the LLM to rate the plays, then records
  the result (which regenerates the checklist). Returns the updated job.

  On success it fans out to the briefing + people-map (see `followups/2`) unless
  `compose: false` is passed (the boot backfill does, to avoid an LLM burst).
  """
  def assess(job, opts \\ [])

  def assess(%Job{} = job, opts) do
    with {:ok, %{text: response}} <-
           OpenRouter.complete(prompt(job), json: true, max_tokens: 1200),
         {:ok, assessments} <- parse(response),
         {:ok, assessed} <- Board.record_assessment(job, assessments) do
      if Keyword.get(opts, :compose, true), do: compose(assessed, assessments)
      {:ok, assessed}
    else
      error ->
        Logger.warning(
          "Strategist: assessing job #{job.id} (#{job.company}) failed: #{inspect(error)}"
        )

        {:error, :not_assessed}
    end
  end

  @doc """
  Which follow-on generators a freshly-assessed `job` should kick: `:brief` when
  it has no briefing yet, `:guide` when networking is a recommended play and no
  targets are mapped yet. Pure — the firing lives in `compose/2`.
  """
  def followups(job, assessments) do
    [
      is_nil(job.job_brief) && :brief,
      networking_recommended?(assessments) && empty?(job.networking_targets) && :guide
    ]
    |> Enum.filter(& &1)
  end

  defp compose(job, assessments) do
    Enum.each(followups(job, assessments), fn
      :brief -> Briefing.brief_async(job)
      :guide -> Networking.guide_async(job)
    end)

    :ok
  end

  defp networking_recommended?(assessments) do
    Enum.any?(assessments, &(&1.slug == "networking" and Plays.recommended?(&1.leverage)))
  end

  defp empty?(nil), do: true
  defp empty?(list) when is_list(list), do: list == []
  defp empty?(_), do: false

  @doc false
  def parse(response) when is_binary(response) do
    with {:ok, %{"plays" => plays}} when is_list(plays) <- Jason.decode(response) do
      assessments =
        plays
        |> Enum.map(&normalize_play/1)
        |> Enum.filter(&(&1.slug in Plays.slugs()))

      if assessments == [], do: {:error, :bad_llm_payload}, else: {:ok, assessments}
    else
      _ -> {:error, :bad_llm_payload}
    end
  end

  defp normalize_play(%{"slug" => slug} = play) when is_binary(slug) do
    %{
      slug: slug,
      leverage: leverage(play["leverage"]),
      rationale: rationale(play["rationale"]),
      steps: steps(play["steps"])
    }
  end

  defp normalize_play(_), do: %{slug: nil, leverage: "skip", rationale: nil, steps: []}

  defp leverage(value) when value in ~w(high medium low skip), do: value
  defp leverage(_), do: "skip"

  defp rationale(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 500)
  defp rationale(_), do: nil

  defp steps(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(6)
  end

  defp steps(_), do: []

  defp prompt(job) do
    """
    You are a job-search strategist. For a specific candidate and listing,
    decide the best way IN — usually NOT the front door. Rate each "play" below
    for how much leverage it carries for THIS listing, and for the worthwhile
    ones spell out the concrete, specific steps to run it well.

    The plays:
    #{plays_catalog()}

    Respond with a single JSON object: {"plays": [ ... ]}, one entry per play
    above, each with exactly:
      "slug"      — the play's slug
      "leverage"  — one of "high", "medium", "low", "skip" (skip = not worth it
                    for this listing)
      "rationale" — one sentence, max ~25 words, why this leverage for this role
      "steps"     — array of 1-4 short, concrete, imperative actions specific to
                    THIS company/role (empty array if leverage is "skip")

    Be specific and honest: prefer "skip" over busywork, and reserve "high" for
    plays that meaningfully beat a cold application here. Judge only from what's
    stated; don't invent named people.

    Candidate profile:
    #{profile()}

    Job:
      Company: #{job.company}
      Title: #{job.title}
      Location: #{job.location || "unknown"}
      Salary: #{job.salary || "unknown"}

    Job posting page text (may be empty if unavailable):
    #{posting_text(job)}
    """
  end

  defp plays_catalog do
    Enum.map_join(Plays.all(), "\n", fn play ->
      "  - #{play.slug}: #{play.name} — #{play.desc}"
    end)
  end

  defp posting_text(%Job{url: url}) when is_binary(url) do
    case Importer.fetch_page_text(url) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp posting_text(_), do: ""

  defp profile do
    Application.get_env(:jobban, :fit_profile) ||
      File.read!(Path.join(Application.app_dir(:jobban, "priv"), "fit_profile.md"))
  end

  defp boot_delay_ms, do: Application.get_env(:jobban, :strategist_boot_delay_ms, 12_000)
  defp between_jobs_ms, do: Application.get_env(:jobban, :strategist_pause_ms, 1_000)
end
