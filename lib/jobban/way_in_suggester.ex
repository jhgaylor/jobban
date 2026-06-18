defmodule Jobban.WayInSuggester do
  @moduledoc """
  LLM assist for the Launchpad: drafts a "way in" playbook (route in, story to
  tell, referral plan) and a few concrete next steps for a job, from the posting
  text and the candidate profile in `priv/fit_profile.md`.

  Same contract as the importer and fit scorer: it's an enhancement, never a
  dependency. Any failure surfaces as `{:error, reason}` and the user just fills
  the playbook in by hand. Called on demand (a button), not fire-and-forget.
  """

  require Logger

  alias Jobban.Board.Job
  alias Jobban.Importer
  alias Jobban.LLM.OpenRouter

  @doc """
  True when suggestions can run: an OpenRouter key is present and the feature
  isn't disabled (it's off in test so the LiveView path is deterministic).
  """
  def enabled? do
    Application.get_env(:jobban, :way_in_suggester_enabled, true) and OpenRouter.configured?()
  end

  @doc """
  Returns `{:ok, %{approach: String.t(), steps: [String.t()]}}` or
  `{:error, reason}`.
  """
  def suggest(%Job{} = job) do
    if enabled?() do
      with {:ok, %{text: response}} <-
             OpenRouter.complete(prompt(job), json: true, max_tokens: 700),
           {:ok, data} <- parse(response) do
        {:ok, data}
      else
        error ->
          Logger.warning(
            "WayInSuggester: suggesting job #{job.id} (#{job.company}) failed: #{inspect(error)}"
          )

          {:error, :not_suggested}
      end
    else
      {:error, :disabled}
    end
  end

  @doc false
  def parse(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{"approach" => approach} = decoded} when is_binary(approach) ->
        {:ok, %{approach: String.trim(approach), steps: steps(decoded["steps"])}}

      _ ->
        {:error, :bad_llm_payload}
    end
  end

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
    You are a job-search strategist helping a specific candidate land an
    interview at a company they want. Given the posting and the candidate
    profile, write the best "way in".

    Respond with a single JSON object with exactly these keys:
      "approach" — a short playbook (3-6 sentences) covering: the strongest
                   route in (referral / cold outreach / direct apply), the
                   story this candidate should tell for THIS role, and a
                   concrete referral or outreach plan. Speak to the candidate
                   ("you"). Be specific to this company and role.
      "steps"    — an array of 2-5 short, concrete next-action strings
                   (imperative, e.g. "Message Dana on the platform team for a
                   referral"). No numbering.

    Judge only from what's stated; don't invent named people or facts.

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
end
