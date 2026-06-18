defmodule Jobban.Board.Plays do
  @moduledoc """
  The codified catalog of "plays" — the ways into a company beyond the front
  door. Each listing gets every play rated for leverage by `Jobban.Strategist`,
  and the recommended ones auto-populate the listing's checklist.

  Fixed in code (a personal, slow-changing menu); add a play here and it flows
  through the strategist prompt, the matrix columns, and task generation. Order
  is the matrix column order, left to right.
  """

  @plays [
    %{
      slug: "networking",
      name: "Networking / referral",
      short: "Net",
      desc: "Get a warm intro or an internal referral instead of applying cold."
    },
    %{
      slug: "pitch",
      name: "Custom pitch",
      short: "Pitch",
      desc: "Write tailored outreach to a specific person (hiring manager, team lead)."
    },
    %{
      slug: "build",
      name: "Build something",
      short: "Build",
      desc: "Ship a small on-topic demo, prototype, or PR that proves the fit."
    },
    %{
      slug: "blog",
      name: "Blog post",
      short: "Blog",
      desc: "Publish something relevant before applying to establish credibility."
    },
    %{
      slug: "apply",
      name: "Cold apply",
      short: "Apply",
      desc: "The front door — submit through the normal application flow."
    }
  ]

  @leverages ~w(high medium low skip)

  @doc "All plays, in matrix-column order."
  def all, do: @plays

  @doc "All play slugs, in order."
  def slugs, do: Enum.map(@plays, & &1.slug)

  @doc "Look up a play by slug, or nil."
  def get(slug), do: Enum.find(@plays, &(&1.slug == slug))

  @doc "Valid leverage ratings, strongest first."
  def leverages, do: @leverages

  @doc "True when a leverage rating means the play is worth running."
  def recommended?(leverage), do: leverage in ~w(high medium low)
end
