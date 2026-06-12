defmodule Jobban.RateLimit do
  @moduledoc """
  Minimal fixed-window rate limiting on a shared ETS table.

  Exists for the unauthenticated `/api/jobs` endpoint — each hit there
  triggers an outbound page fetch and possibly a paid LLM call, so it
  can't be a free-for-all. Windows are clock-aligned, not sliding; good
  enough at personal-board scale.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval :timer.minutes(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Counts a hit for `key` and returns whether it stays within `limit` hits
  per `window_ms`.
  """
  def allow?(key, limit, window_ms) do
    window = div(System.system_time(:millisecond), window_ms)
    expires_at = (window + 1) * window_ms

    count =
      :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, expires_at})

    count <= limit
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
