defmodule JobbanWeb.Api.JobControllerTest do
  use JobbanWeb.ConnCase, async: true

  import Jobban.BoardFixtures

  alias Jobban.Board

  @jobposting_html """
  <html><head><script type="application/ld+json">
  {"@type":"JobPosting","title":"Platform Engineer",
   "hiringOrganization":{"name":"Tailscale"},
   "jobLocationType":"TELECOMMUTE"}
  </script></head><body></body></html>
  """

  setup do
    [wishlist | _] = stages_fixture()
    %{wishlist: wishlist}
  end

  # The per-ip rate bucket is shared across async tests, so every test
  # claims its own client IP via the x-forwarded-for header.
  defp post_url(conn, url, ip) do
    conn
    |> put_req_header("x-forwarded-for", ip)
    |> post(~p"/api/jobs", %{"url" => url})
  end

  test "yeeting a posting URL creates a card in wishlist", %{conn: conn, wishlist: wishlist} do
    Req.Test.stub(Jobban.Importer, fn conn -> Req.Test.html(conn, @jobposting_html) end)

    conn = post_url(conn, "https://jobs.ashbyhq.com/tailscale/x", "203.0.113.1")

    assert %{"status" => "created", "job" => job} = json_response(conn, 201)
    assert %{"company" => "Tailscale", "title" => "Platform Engineer"} = job

    assert [%{company: "Tailscale", stage_id: stage_id}] = [Board.get_job!(job["id"])]
    assert stage_id == wishlist.id
  end

  test "re-yeeting the same URL is idempotent", %{conn: conn, wishlist: wishlist} do
    url = "https://jobs.ashbyhq.com/tailscale/x"
    job_fixture(wishlist, %{"url" => url})

    conn = post_url(conn, url, "203.0.113.2")

    assert %{"status" => "already_tracked"} = json_response(conn, 200)
    assert Board.stats().total == 1
  end

  test "pages without a job posting are a 422", %{conn: conn} do
    Req.Test.stub(Jobban.Importer, fn conn ->
      Req.Test.html(conn, "<html><body>nothing here</body></html>")
    end)

    conn = post_url(conn, "https://example.com/not-a-job", "203.0.113.3")

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "couldn't find a job posting"
    assert Board.stats().total == 0
  end

  test "garbage urls are a 422, missing url a 400", %{conn: conn} do
    conn1 = post_url(conn, "not a url", "203.0.113.4")
    assert %{"error" => _} = json_response(conn1, 422)

    conn2 = post(conn, ~p"/api/jobs", %{"nope" => "x"})
    assert %{"error" => _} = json_response(conn2, 400)
  end

  test "per-ip rate limit kicks in", %{conn: conn} do
    Req.Test.stub(Jobban.Importer, fn conn -> Req.Test.html(conn, @jobposting_html) end)
    ip = "203.0.113.5"

    # test config allows 2/minute per ip
    post_url(conn, "https://jobs.ashbyhq.com/a", ip)
    post_url(conn, "https://jobs.ashbyhq.com/b", ip)
    conn = post_url(conn, "https://jobs.ashbyhq.com/c", ip)

    assert %{"error" => error} = json_response(conn, 429)
    assert error =~ "rate limited"
  end
end
