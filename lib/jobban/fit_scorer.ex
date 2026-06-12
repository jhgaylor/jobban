defmodule Jobban.FitScorer do
  @moduledoc """
  LLM fit check: scores how well a job matches the candidate profile in
  `priv/fit_profile.md` on a 1–5 scale, with a one-line rationale.

  Runs fire-and-forget after every create (`Jobban.Board.create_job/1`) and
  as a boot-time backfill over jobs that were created before scoring existed
  or whose last attempt failed. Same contract as the importer's LLM tier:
  any failure leaves the job unscored and never blocks the pipeline.
  """

  require Logger

  alias Jobban.Board
  alias Jobban.Board.Job
  alias Jobban.Importer
  alias Jobban.LLM.OpenRouter

  @doc """
  True when scoring can run: an OpenRouter key is present and the feature
  isn't disabled (it's off in test so creates stay deterministic).
  """
  def enabled? do
    Application.get_env(:jobban, :fit_scoring_enabled, true) and OpenRouter.configured?()
  end

  @doc "Fire-and-forget scoring of one job. No-op when scoring is disabled."
  def score_async(%Job{} = job) do
    if enabled?() do
      Task.Supervisor.start_child(Jobban.TaskSupervisor, fn -> score(job) end)
    end

    :ok
  end

  @doc """
  Boot-time backfill: scores every job with no fit score yet, serially with
  a pause between calls so a large board doesn't burst-hit OpenRouter (or
  re-fetch dozens of posting pages at once). Supervised as a one-shot Task.
  """
  def backfill do
    if enabled?() do
      Process.sleep(boot_delay_ms())
      jobs = Board.jobs_missing_fit()

      if jobs != [] do
        Logger.info("FitScorer: backfilling #{length(jobs)} unscored job(s)")
      end

      Enum.each(jobs, fn job ->
        score(job)
        Process.sleep(between_jobs_ms())
      end)
    end

    :ok
  end

  @doc """
  Scores one job synchronously: re-fetches the posting page when the job has
  a URL, asks the LLM for `{score, summary}`, and records the result.
  """
  def score(%Job{} = job) do
    with {:ok, %{text: response}} <-
           OpenRouter.complete(prompt(job), json: true, max_tokens: 300),
         {:ok, score, summary} <- parse(response) do
      Board.record_fit(job, score, summary)
    else
      error ->
        Logger.warning(
          "FitScorer: scoring job #{job.id} (#{job.company}) failed: #{inspect(error)}"
        )

        {:error, :not_scored}
    end
  end

  @doc false
  def parse(response) when is_binary(response) do
    with {:ok, %{"score" => score} = decoded} when is_integer(score) and score in 1..5 <-
           Jason.decode(response) do
      {:ok, score, summary(decoded["summary"])}
    else
      _ -> {:error, :bad_llm_payload}
    end
  end

  defp summary(value) when is_binary(value), do: value |> String.trim() |> String.slice(0, 500)
  defp summary(_), do: nil

  defp prompt(job) do
    """
    You are screening job postings for a specific candidate. Score how well
    this job fits them:
      5 — bullseye: role, level, stack, and logistics all line up
      4 — strong: worth prioritizing, only minor mismatches
      3 — plausible: could work, but with real tradeoffs
      2 — weak: significant mismatch in level, domain, or logistics
      1 — poor: wrong kind of role, or hits a dealbreaker

    Respond with a single JSON object with exactly these keys:
      "score"   — integer 1-5
      "summary" — one sentence, max ~25 words, naming the decisive factor(s)

    Judge only from what's stated; missing information is neutral, not negative.

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

  defp boot_delay_ms, do: Application.get_env(:jobban, :fit_backfill_boot_delay_ms, 10_000)
  defp between_jobs_ms, do: Application.get_env(:jobban, :fit_backfill_pause_ms, 1_000)
end
