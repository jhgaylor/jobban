defmodule Jobban.Importer do
  @moduledoc """
  Turns a job-posting URL (Greenhouse, Lever, Ashby, careers pages, …) into
  job attrs ready for `Jobban.Board.create_job/1`.

  Extraction is tiered by trust:

    1. schema.org `JobPosting` JSON-LD — most ATSs embed it; exact data
    2. OpenRouter LLM over the page text — fills whatever JSON-LD missed
       (skipped entirely when no API key is configured)
    3. OpenGraph/title meta tags — last-resort guesses

  Returns `{:ok, attrs}` with string keys, or `{:error, reason}` where reason
  is one of `:invalid_url`, `:blocked_host`, `:no_job_found`,
  `{:http_error, status}`, `:transport_error`.
  """

  require Logger

  alias Jobban.LLM.OpenRouter

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
  @fields ~w(company title location salary)

  def import_from_url(url) when is_binary(url) do
    url = String.trim(url)

    with :ok <- validate_url(url),
         :ok <- check_host(url),
         {:ok, html} <- fetch(url) do
      extract(html, url)
    end
  end

  @doc """
  Fetches a URL and returns its visible page text — same validation, SSRF
  guard, and text extraction as an import. Used by the fit scorer to give
  the LLM the full posting, since jobs only persist the headline fields.
  """
  def fetch_page_text(url) when is_binary(url) do
    with :ok <- validate_url(url),
         :ok <- check_host(url),
         {:ok, html} <- fetch(url) do
      {:ok, page_text(html)}
    end
  end

  @doc false
  # Public for tests — pure extraction over fetched HTML.
  def extract(html, url) do
    jsonld = extract_jsonld(html)
    meta = extract_meta(html)
    llm = if Enum.any?(@fields, &(jsonld[&1] == nil)), do: llm_extract(html, url), else: %{}

    merged =
      Map.new(@fields, fn field ->
        {field, jsonld[field] || llm[field] || meta[field]}
      end)

    if merged["company"] && merged["title"] do
      {:ok,
       merged
       |> Map.put("url", url)
       |> Map.put("source", source_for_url(url))}
    else
      {:error, :no_job_found}
    end
  end

  @doc false
  def source_for_url(url) do
    host = URI.parse(url).host || ""

    cond do
      host =~ "linkedin.com" -> "LinkedIn"
      host =~ "ycombinator.com" -> "Hacker News"
      host =~ ~r/indeed|glassdoor|wellfound|otta\./ -> "Job board"
      true -> "Company site"
    end
  end

  ## Fetch

  defp validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, :invalid_url}
    end
  end

  # SSRF guard: the importer fetches arbitrary URLs from inside the
  # cluster and is reachable unauthenticated via /api/jobs, so refuse
  # anything resolving to private/loopback address space. Redirects and
  # DNS rebinding can still slip past — acceptable residual risk for a
  # personal board. Off in test (config) so stubs don't need DNS.
  defp check_host(url) do
    if Application.get_env(:jobban, :importer_block_private_hosts, true) and
         blocked_host?(URI.parse(url).host) do
      {:error, :blocked_host}
    else
      :ok
    end
  end

  @doc false
  def blocked_host?(host) when is_binary(host) do
    host
    |> resolve()
    |> Enum.any?(&private_addr?/1)
  end

  def blocked_host?(_), do: false

  # Unresolvable hosts come back [] — let the fetch fail naturally.
  defp resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.getaddrs(charlist, :inet) do
      {:ok, addrs} ->
        addrs

      {:error, _} ->
        case :inet.getaddrs(charlist, :inet6) do
          {:ok, addrs} -> addrs
          {:error, _} -> []
        end
    end
  end

  defp private_addr?({0, _, _, _}), do: true
  defp private_addr?({10, _, _, _}), do: true
  defp private_addr?({100, b, _, _}) when b in 64..127, do: true
  defp private_addr?({127, _, _, _}), do: true
  defp private_addr?({169, 254, _, _}), do: true
  defp private_addr?({172, b, _, _}) when b in 16..31, do: true
  defp private_addr?({192, 168, _, _}), do: true
  defp private_addr?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_addr?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_addr?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_addr?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true

  defp private_addr?({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: private_addr?({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})

  defp private_addr?(_), do: false

  defp fetch(url) do
    req_options =
      [
        headers: [{"user-agent", @user_agent}, {"accept", "text/html,application/xhtml+xml"}],
        max_redirects: 5,
        receive_timeout: 15_000,
        retry: false,
        decode_body: false
      ] ++ Application.get_env(:jobban, :importer_req_options, [])

    case Req.get(url, req_options) do
      {:ok, %Req.Response{status: status, body: body}}
      when status in 200..299 and is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, e} ->
        Logger.warning("Importer fetch failed for #{url}: #{inspect(e)}")
        {:error, :transport_error}
    end
  end

  ## Tier 1 — schema.org JobPosting JSON-LD

  defp extract_jsonld(html) do
    with {:ok, doc} <- Floki.parse_document(html),
         %{} = posting <- find_jobposting(doc) do
      %{
        "company" => presence(get_in(posting, ["hiringOrganization", "name"])),
        "title" => presence(posting["title"]),
        "location" => jsonld_location(posting),
        "salary" => jsonld_salary(posting["baseSalary"])
      }
    else
      _ -> %{}
    end
  end

  defp find_jobposting(doc) do
    doc
    |> Floki.find(~s(script[type="application/ld+json"]))
    |> Enum.flat_map(fn {_tag, _attrs, children} ->
      case Jason.decode(IO.iodata_to_binary(children)) do
        {:ok, decoded} -> List.wrap(decoded) |> Enum.flat_map(&unwrap_graph/1)
        _ -> []
      end
    end)
    |> Enum.find(fn node -> is_map(node) and node["@type"] in ["JobPosting", ["JobPosting"]] end)
  end

  defp unwrap_graph(%{"@graph" => graph}) when is_list(graph), do: graph
  defp unwrap_graph(node), do: [node]

  defp jsonld_location(%{"jobLocationType" => "TELECOMMUTE"}), do: "Remote"

  defp jsonld_location(%{"jobLocation" => location}) do
    location
    |> List.wrap()
    |> List.first()
    |> case do
      %{"address" => address} when is_map(address) ->
        ["addressLocality", "addressRegion", "addressCountry"]
        |> Enum.map(&presence(address[&1]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> case do
          [] -> nil
          parts -> Enum.join(parts, ", ")
        end

      %{"address" => address} when is_binary(address) ->
        presence(address)

      _ ->
        nil
    end
  end

  defp jsonld_location(_), do: nil

  defp jsonld_salary(%{"value" => value} = base) when is_map(value) do
    symbol = currency_symbol(base["currency"])
    suffix = salary_suffix(value["unitText"])

    case {value["minValue"], value["maxValue"], value["value"]} do
      {min, max, _} when is_number(min) and is_number(max) ->
        "#{symbol}#{fmt_amount(min)}–#{symbol}#{fmt_amount(max)}#{suffix}"

      {_, _, single} when is_number(single) ->
        "#{symbol}#{fmt_amount(single)}#{suffix}"

      _ ->
        nil
    end
  end

  defp jsonld_salary(_), do: nil

  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol(code) when is_binary(code), do: code <> " "
  defp currency_symbol(_), do: "$"

  defp salary_suffix("HOUR"), do: "/hr"
  defp salary_suffix(_), do: ""

  defp fmt_amount(n) when n >= 1000, do: "#{round(n / 1000)}k"
  defp fmt_amount(n), do: "#{round(n)}"

  ## Tier 2 — LLM over page text

  defp llm_extract(html, url) do
    text = page_text(html)

    prompt = """
    Extract the job posting details from this web page text. Respond with a
    single JSON object with exactly these keys:
      "company"        — the hiring company's name (not the ATS/job board name)
      "title"          — the role title
      "location"       — short location like "Remote (US)" or "Austin, TX", or null
      "salary"         — short compensation range like "$170k–$200k", or null
      "is_job_posting" — false if this page is not a job posting

    Use null for anything not stated. Do not invent values.

    Page URL: #{url}
    Page text:
    #{text}
    """

    with true <- text != "",
         {:ok, %{text: response}} <- OpenRouter.complete(prompt, json: true, max_tokens: 300) do
      parse_llm_payload(response)
    else
      _ -> %{}
    end
  end

  @doc false
  def parse_llm_payload(response) when is_binary(response) do
    case Jason.decode(response) do
      {:ok, %{"is_job_posting" => false}} ->
        %{}

      {:ok, %{} = decoded} ->
        Map.new(@fields, fn field ->
          {field,
           case decoded[field] do
             value when is_binary(value) -> presence(value)
             _ -> nil
           end}
        end)

      _ ->
        %{}
    end
  end

  defp page_text(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.filter_out("script")
        |> Floki.filter_out("style")
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 12_000)

      _ ->
        ""
    end
  end

  ## Tier 3 — meta tags

  defp extract_meta(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        title_tag = presence(Floki.text(Floki.find(doc, "title")))
        {gh_title, gh_company} = greenhouse_title_pattern(title_tag)

        %{
          "company" => meta_content(doc, "og:site_name") || gh_company,
          "title" => meta_content(doc, "og:title") || gh_title || title_tag
        }

      _ ->
        %{}
    end
  end

  # Greenhouse renders "<title>Job Application for {role} at {company}</title>".
  defp greenhouse_title_pattern(nil), do: {nil, nil}

  defp greenhouse_title_pattern(title) do
    case Regex.run(~r/^Job Application for (.+) at (.+?)(?:\s*\|.*)?$/, title) do
      [_, role, company] -> {presence(role), presence(company)}
      _ -> {nil, nil}
    end
  end

  defp meta_content(doc, property) do
    doc
    |> Floki.find(~s(meta[property="#{property}"]))
    |> Floki.attribute("content")
    |> List.first()
    |> presence()
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
