# Idempotent seeds: ensures the five job-search stages exist.
# Run with `mix run priv/repo/seeds.exs` (also run on boot in prod).

alias Jobban.Repo
alias Jobban.Board.Stage

[
  %{name: "Wishlist", slug: "wishlist", position: 0},
  %{name: "Applied", slug: "applied", position: 1},
  %{name: "Interviewing", slug: "interviewing", position: 2},
  %{name: "Offer", slug: "offer", position: 3},
  %{name: "Rejected", slug: "rejected", position: 4}
]
|> Enum.each(fn attrs ->
  Repo.insert!(
    Stage.changeset(%Stage{}, attrs),
    on_conflict: {:replace, [:name, :position, :updated_at]},
    conflict_target: :slug
  )
end)
