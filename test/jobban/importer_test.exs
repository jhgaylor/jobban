defmodule Jobban.ImporterTest do
  use ExUnit.Case, async: true

  alias Jobban.Importer

  @greenhouse_url "https://boards.greenhouse.io/acme/jobs/123"

  defp jsonld_page(payload) do
    """
    <html><head>
      <title>Job Application for Staff Engineer at Acme | Greenhouse</title>
      <script type="application/ld+json">#{Jason.encode!(payload)}</script>
    </head><body>Apply now</body></html>
    """
  end

  @jobposting %{
    "@context" => "https://schema.org/",
    "@type" => "JobPosting",
    "title" => "Staff Platform Engineer",
    "hiringOrganization" => %{"@type" => "Organization", "name" => "Acme Corp"},
    "jobLocation" => %{
      "@type" => "Place",
      "address" => %{"addressLocality" => "Austin", "addressRegion" => "TX"}
    },
    "baseSalary" => %{
      "@type" => "MonetaryAmount",
      "currency" => "USD",
      "value" => %{
        "@type" => "QuantitativeValue",
        "minValue" => 170_000,
        "maxValue" => 200_000,
        "unitText" => "YEAR"
      }
    }
  }

  describe "extract/2 (JSON-LD tier)" do
    test "extracts a full JobPosting" do
      assert {:ok, attrs} = Importer.extract(jsonld_page(@jobposting), @greenhouse_url)

      assert attrs["company"] == "Acme Corp"
      assert attrs["title"] == "Staff Platform Engineer"
      assert attrs["location"] == "Austin, TX"
      assert attrs["salary"] == "$170k–$200k"
      assert attrs["url"] == @greenhouse_url
      assert attrs["source"] == "Company site"
    end

    test "handles @graph wrapping and remote locations" do
      payload = %{
        "@context" => "https://schema.org/",
        "@graph" => [
          %{"@type" => "WebSite", "name" => "careers"},
          @jobposting
          |> Map.delete("jobLocation")
          |> Map.put("jobLocationType", "TELECOMMUTE")
          |> Map.delete("baseSalary")
        ]
      }

      assert {:ok, attrs} = Importer.extract(jsonld_page(payload), @greenhouse_url)
      assert attrs["location"] == "Remote"
      assert attrs["salary"] == nil
    end

    test "falls back to meta tags when no JSON-LD and no LLM key" do
      html = """
      <html><head>
        <meta property="og:site_name" content="Linear" />
        <meta property="og:title" content="Senior Product Engineer" />
      </head><body></body></html>
      """

      assert {:ok, attrs} = Importer.extract(html, "https://linear.app/careers/x")
      assert attrs["company"] == "Linear"
      assert attrs["title"] == "Senior Product Engineer"
    end

    test "parses the Greenhouse title pattern when JSON-LD is absent" do
      html = """
      <html><head>
        <title>Job Application for Director of Engineering at GitLab</title>
        <meta property="og:title" content="Director of Engineering" />
      </head><body></body></html>
      """

      assert {:ok, attrs} = Importer.extract(html, @greenhouse_url)
      assert attrs["company"] == "GitLab"
      assert attrs["title"] == "Director of Engineering"
    end

    test "errors when nothing identifies a job" do
      assert {:error, :no_job_found} =
               Importer.extract("<html><body>404</body></html>", @greenhouse_url)
    end
  end

  describe "source_for_url/1" do
    test "maps known hosts" do
      assert Importer.source_for_url("https://www.linkedin.com/jobs/view/1") == "LinkedIn"
      assert Importer.source_for_url("https://news.ycombinator.com/item?id=1") == "Hacker News"
      assert Importer.source_for_url("https://www.indeed.com/viewjob?jk=1") == "Job board"
      assert Importer.source_for_url(@greenhouse_url) == "Company site"
    end
  end

  describe "parse_llm_payload/1" do
    test "accepts well-formed payloads and trims" do
      json =
        ~s({"company":" Fly.io ","title":"Infra Eng","location":null,"salary":"$180k","is_job_posting":true})

      assert %{
               "company" => "Fly.io",
               "title" => "Infra Eng",
               "location" => nil,
               "salary" => "$180k"
             } =
               Importer.parse_llm_payload(json)
    end

    test "rejects non-postings and garbage" do
      assert Importer.parse_llm_payload(~s({"is_job_posting":false})) == %{}
      assert Importer.parse_llm_payload("not json") == %{}
      assert Importer.parse_llm_payload(~s({"company":42})) |> Map.get("company") == nil
    end
  end

  describe "import_from_url/1 (fetch via Req.Test)" do
    test "fetches and extracts" do
      Req.Test.stub(Jobban.Importer, fn conn ->
        Req.Test.html(conn, jsonld_page(@jobposting))
      end)

      assert {:ok, attrs} = Importer.import_from_url(@greenhouse_url)
      assert attrs["company"] == "Acme Corp"
    end

    test "surfaces HTTP errors" do
      Req.Test.stub(Jobban.Importer, fn conn ->
        Plug.Conn.send_resp(conn, 404, "gone")
      end)

      assert {:error, {:http_error, 404}} = Importer.import_from_url(@greenhouse_url)
    end

    test "rejects garbage urls without fetching" do
      assert {:error, :invalid_url} = Importer.import_from_url("acme jobs")
      assert {:error, :invalid_url} = Importer.import_from_url("ftp://acme.io/job")
    end
  end
end
