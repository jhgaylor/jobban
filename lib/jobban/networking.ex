defmodule Jobban.Networking do
  @moduledoc """
  LLM help for the networking play — the part Jake finds oblique: *who* to reach
  at a company and *how* to actually find them.

  Two on-demand calls:
    * `guide/1` — for a listing, who to reach (hiring manager, recruiter, team
      IC, warm connection) with the likely title for this role and a concrete
      recipe for finding each. Persisted via `Board.record_networking_targets/2`.
    * `draft/2` — given a target, a LinkedIn DM and an email (subject + body)
      tailored from the posting + the candidate profile. Returned for copy, not
      persisted.

  Same contract as the rest: an enhancement, never a dependency. Gated on a key
  and `networking_enabled` (off in test).
  """

  require Logger

  alias Jobban.Board
  alias Jobban.Board.Job
  alias Jobban.Importer
  alias Jobban.LLM.OpenRouter

  def enabled? do
    Application.get_env(:jobban, :networking_enabled, true) and OpenRouter.configured?()
  end

  @doc """
  Generates and persists the "who to reach + how to find them" targets for a
  job. Returns the updated job, or `{:error, reason}`.
  """
  def guide(%Job{} = job) do
    with true <- enabled?() or :disabled,
         {:ok, %{text: response}} <-
           OpenRouter.complete(guide_prompt(job), json: true, max_tokens: 1200),
         {:ok, targets} <- parse_guide(response) do
      Board.record_networking_targets(job, targets)
    else
      :disabled ->
        {:error, :disabled}

      error ->
        Logger.warning("Networking.guide job #{job.id} (#{job.company}): #{inspect(error)}")
        {:error, :no_guide}
    end
  end

  @doc """
  Drafts outreach to one target. `target` is a map with at least `:label`, plus
  optional `:title_hint` and `:name` (a real person you've identified). Returns
  `{:ok, %{linkedin, email_subject, email_body}}` or `{:error, reason}`.
  """
  def draft(%Job{} = job, target) when is_map(target) do
    with true <- enabled?() or :disabled,
         {:ok, %{text: response}} <-
           OpenRouter.complete(draft_prompt(job, target), json: true, max_tokens: 900),
         {:ok, message} <- parse_draft(response) do
      {:ok, message}
    else
      :disabled ->
        {:error, :disabled}

      error ->
        Logger.warning("Networking.draft job #{job.id} (#{job.company}): #{inspect(error)}")
        {:error, :no_draft}
    end
  end

  ## Parsing

  @doc false
  def parse_guide(response) when is_binary(response) do
    with {:ok, %{"targets" => targets}} when is_list(targets) <- Jason.decode(response) do
      parsed =
        targets
        |> Enum.map(&normalize_target/1)
        |> Enum.reject(&(&1.label in [nil, ""]))
        |> Enum.take(6)

      if parsed == [], do: {:error, :bad_llm_payload}, else: {:ok, parsed}
    else
      _ -> {:error, :bad_llm_payload}
    end
  end

  defp normalize_target(t) when is_map(t) do
    %{
      label: trimmed(t["label"]),
      title_hint: trimmed(t["title_hint"]),
      why: trimmed(t["why"]),
      how_to_find: trimmed(t["how_to_find"]),
      referral_path: trimmed(t["referral_path"])
    }
  end

  defp normalize_target(_),
    do: %{label: nil, title_hint: nil, why: nil, how_to_find: nil, referral_path: nil}

  @doc false
  def parse_draft(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{"linkedin" => li} = m} when is_binary(li) ->
        {:ok,
         %{
           linkedin: String.trim(li),
           email_subject: trimmed(m["email_subject"]) || "",
           email_body: trimmed(m["email_body"]) || ""
         }}

      _ ->
        {:error, :bad_llm_payload}
    end
  end

  defp trimmed(v) when is_binary(v), do: String.trim(v)
  defp trimmed(_), do: nil

  ## Prompts

  defp guide_prompt(job) do
    """
    A candidate wants to network their way into a specific role instead of cold
    applying — but finding the right people feels oblique to them. For THIS
    listing, lay out who to reach and, crucially, HOW to actually find each one.

    Respond with a single JSON object: {"targets": [ ... ]} with 3-5 entries,
    each with exactly:
      "label"       — who they are, e.g. "Hiring manager", "Recruiter",
                      "Engineer on the team", "Warm connection"
      "title_hint"  — the likely job title for THIS role's context, e.g.
                      "Engineering Manager, Payments Platform" (best guess)
      "why"          — one sentence on why this person is worth reaching
      "how_to_find"  — concrete, specific steps to find them. Name the exact
                       moves: the LinkedIn search/filter to run (give the search
                       text), how to infer the hiring manager (the person this
                       role reports up to), checking the posting for a named
                       recruiter, the company People tab filtered by title, and
                       how to spot a warm/mutual connection. Be a teacher, not
                       vague.
      "referral_path" — the POINT of this contact: what to actually get from
                       them and the concrete move to turn it into a referral or
                       a real advance (e.g. "ask for 15 min of advice, then if
                       it clicks ask them to flag your application to the hiring
                       manager"). One or two sentences, specific to their role.

    Order from easiest-first-touch to highest-value. Be specific to this
    company and role; don't invent named individuals.

    Candidate profile:
    #{profile()}

    Job:
      Company: #{job.company}
      Title: #{job.title}
      Location: #{job.location || "unknown"}

    Job posting page text (may be empty):
    #{posting_text(job)}
    """
  end

  defp draft_prompt(job, target) do
    who =
      [target[:name], target[:label], target[:title_hint]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join(" — ")

    """
    Write outreach from the candidate below to this person at #{job.company},
    for the role "#{job.title}". Recipient: #{who}.

    Respond with a single JSON object with exactly:
      "linkedin"      — a LinkedIn message: warm, specific, ~400-600 characters,
                        no subject line, one clear ask (a short chat / a
                        referral / advice). Lead with a genuine, specific hook
                        about the company or role.
      "email_subject" — a short, specific subject line
      "email_body"    — a concise email (4-8 sentences): hook, who you are in one
                        line, why this role/company, the ask, easy out. Sign off
                        with a placeholder name.

    Sound like a sharp peer, not a form letter. Use only what's stated; if you
    don't know the recipient's name, write so it works without it. No emojis.

    Candidate profile:
    #{profile()}

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

  defp profile do
    Application.get_env(:jobban, :fit_profile) ||
      File.read!(Path.join(Application.app_dir(:jobban, "priv"), "fit_profile.md"))
  end
end
