defmodule Jobban.Briefing do
  @moduledoc """
  LLM briefing for a listing: what the company does, where this role likely sits
  within it, and why that role matters strategically to the company. Prep for
  interviews, pitches, and networking conversations.

  On-demand (a button in the listing detail). `brief/1` generates and persists
  via `Board.record_brief/2`. Same contract as the rest: an enhancement, gated
  on a key and `briefing_enabled` (off in test).
  """

  require Logger

  alias Jobban.Board
  alias Jobban.Board.Job
  alias Jobban.Importer
  alias Jobban.LLM.OpenRouter

  def enabled? do
    Application.get_env(:jobban, :briefing_enabled, true) and OpenRouter.configured?()
  end

  @doc "Generates and persists a job's briefing. Returns the updated job."
  def brief(%Job{} = job) do
    with true <- enabled?() or :disabled,
         {:ok, %{text: response}} <-
           OpenRouter.complete(prompt(job), json: true, max_tokens: 900),
         {:ok, attrs} <- parse(response) do
      Board.record_brief(job, attrs)
    else
      :disabled ->
        {:error, :disabled}

      error ->
        Logger.warning("Briefing.brief job #{job.id} (#{job.company}): #{inspect(error)}")
        {:error, :no_brief}
    end
  end

  @doc false
  def parse(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{} = m} ->
        attrs = %{
          company_overview: trimmed(m["company_overview"]),
          role_in_company: trimmed(m["role_in_company"]),
          strategic_value: trimmed(m["strategic_value"])
        }

        if Enum.all?(Map.values(attrs), &is_nil/1),
          do: {:error, :bad_llm_payload},
          else: {:ok, attrs}

      _ ->
        {:error, :bad_llm_payload}
    end
  end

  defp trimmed(v) when is_binary(v), do: v |> String.trim() |> nil_if_empty()
  defp trimmed(_), do: nil

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  defp prompt(job) do
    """
    Brief a candidate on a company and role so they can speak about it credibly
    in interviews and outreach. Be concrete and grounded; where you're inferring,
    say "likely". Don't pad.

    Respond with a single JSON object with exactly:
      "company_overview" — what the company actually does: product, who it's for,
                           business model, and where it sits in its market.
                           3-5 sentences.
      "role_in_company"  — where THIS role likely sits: the team/function, its
                           scope and day-to-day, who it probably reports to, and
                           how senior it is. 3-5 sentences, hedged where unsure.
      "strategic_value"  — why this role matters to the company's goals right
                           now: the lever it pulls (revenue, infra, growth,
                           risk), and why they're likely hiring for it. 3-5
                           sentences.

    Judge from what's stated plus reasonable inference; don't invent specific
    figures or names.

    Job:
      Company: #{job.company}
      Title: #{job.title}
      Location: #{job.location || "unknown"}

    Job posting page text (may be empty):
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
end
