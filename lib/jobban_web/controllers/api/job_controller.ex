defmodule JobbanWeb.Api.JobController do
  use JobbanWeb, :controller

  alias Jobban.{Board, Importer, RateLimit}

  @default_limits [per_ip: {5, 60_000}, global: {30, 3_600_000}]

  @doc """
  Unauthenticated by design: lets a share-sheet shortcut, bookmarklet, or
  plain curl yeet a posting URL onto the board without a session. The
  importer does the extraction; the card lands in the leftmost stage.
  Rate limiting + the importer's private-host guard keep it from being a
  free fetch/LLM proxy.
  """
  def create(conn, %{"url" => url}) when is_binary(url) do
    url = String.trim(url)

    cond do
      rate_limited?(conn) ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate limited — try again in a bit"})

      job = Board.get_job_by_url(url) ->
        json(conn, %{status: "already_tracked", job: job_json(job)})

      true ->
        import_job(conn, url)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: ~s(send a "url" field with the job posting link)})
  end

  defp import_job(conn, url) do
    with {:ok, attrs} <- Importer.import_from_url(url),
         {:ok, job} <- Board.create_job(Map.put(attrs, "stage_id", Board.first_stage().id)) do
      conn
      |> put_status(:created)
      |> json(%{status: "created", job: job_json(job)})
    else
      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "couldn't save the imported job"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message(reason)})
    end
  end

  defp job_json(job) do
    Map.take(job, [:id, :company, :title, :location, :salary, :url, :source])
  end

  defp error_message(:invalid_url), do: "that doesn't look like a link"
  defp error_message(:blocked_host), do: "that host isn't importable"
  defp error_message(:no_job_found), do: "couldn't find a job posting there"
  defp error_message({:http_error, status}), do: "the site answered with HTTP #{status}"
  defp error_message(:transport_error), do: "couldn't reach that site"
  defp error_message(_), do: "import failed"

  defp rate_limited?(conn) do
    limits = Application.get_env(:jobban, :yeet_rate_limits, @default_limits)
    {ip_limit, ip_window} = Keyword.fetch!(limits, :per_ip)
    {global_limit, global_window} = Keyword.fetch!(limits, :global)

    not RateLimit.allow?({:yeet, client_ip(conn)}, ip_limit, ip_window) or
      not RateLimit.allow?(:yeet_global, global_limit, global_window)
  end

  # Rightmost x-forwarded-for entry is the one Traefik appended (the hop
  # it actually saw); earlier entries are client-controlled.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
