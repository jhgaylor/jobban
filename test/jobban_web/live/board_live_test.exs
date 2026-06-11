defmodule JobbanWeb.BoardLiveTest do
  use JobbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Jobban.BoardFixtures

  alias Jobban.Board

  setup do
    [wishlist, applied | _] = stages_fixture()
    %{wishlist: wishlist, applied: applied}
  end

  test "renders all stage columns", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")

    for name <- ~w(Wishlist Applied Interviewing Offer Rejected) do
      assert html =~ name
    end
  end

  test "quick-add creates a job in the chosen column", %{conn: conn, wishlist: wishlist} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("button[phx-value-stage-id='#{wishlist.id}']")
    |> render_click()

    view
    |> form("#quick-add-#{wishlist.id}-0", %{
      "job" => %{"stage_id" => wishlist.id, "company" => "Tailscale", "title" => "Platform Eng"}
    })
    |> render_submit()

    assert render(view) =~ "Tailscale"
    [stage | _] = Board.list_stages()
    assert [%{company: "Tailscale"}] = stage.jobs
  end

  test "move_job event moves a card between columns", %{
    conn: conn,
    wishlist: wishlist,
    applied: applied
  } do
    job = job_fixture(wishlist)
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "move_job", %{
      "id" => to_string(job.id),
      "stage_id" => to_string(applied.id),
      "index" => 0
    })

    assert Board.get_job!(job.id).stage_id == applied.id
  end

  test "opening a card shows the detail modal with activity", %{conn: conn, wishlist: wishlist} do
    job = job_fixture(wishlist, %{"company" => "Fly.io"})
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("#job-#{job.id}")
      |> render_click()

    assert html =~ "job-form"
    assert html =~ "Fly.io"
    assert html =~ "Added Staff Engineer at Fly.io"
  end

  test "editing a job through the modal", %{conn: conn, wishlist: wishlist} do
    job = job_fixture(wishlist)
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#job-#{job.id}") |> render_click()

    view
    |> form("#job-form", %{"job" => %{"salary" => "$200k", "excitement" => "5"}})
    |> render_submit()

    reloaded = Board.get_job!(job.id)
    assert reloaded.salary == "$200k"
    assert reloaded.excitement == 5
  end

  test "importing from an ATS link creates a card asynchronously", %{
    conn: conn,
    wishlist: wishlist
  } do
    Req.Test.stub(Jobban.Importer, fn conn ->
      Req.Test.html(conn, """
      <html><head><script type="application/ld+json">
      {"@type":"JobPosting","title":"Platform Engineer",
       "hiringOrganization":{"name":"Tailscale"},
       "jobLocationType":"TELECOMMUTE"}
      </script></head><body></body></html>
      """)
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-value-stage-id='#{wishlist.id}']") |> render_click()

    view
    |> form("#quick-import-#{wishlist.id}-0", %{
      "import" => %{"stage_id" => wishlist.id, "url" => "https://jobs.ashbyhq.com/tailscale/x"}
    })
    |> render_submit()

    html = render_async(view)
    assert html =~ "Tailscale"
    assert html =~ "Imported Platform Engineer at Tailscale"

    [stage | _] = Board.list_stages()
    assert [%{company: "Tailscale", location: "Remote", url: "https://jobs.ashbyhq.com/tailscale/x"}] =
             stage.jobs
  end

  test "failed imports surface a friendly error", %{conn: conn, wishlist: wishlist} do
    Req.Test.stub(Jobban.Importer, fn conn -> Plug.Conn.send_resp(conn, 410, "gone") end)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("button[phx-value-stage-id='#{wishlist.id}']") |> render_click()

    view
    |> form("#quick-import-#{wishlist.id}-0", %{
      "import" => %{"stage_id" => wishlist.id, "url" => "https://example.com/dead"}
    })
    |> render_submit()

    html = render_async(view)
    assert html =~ "HTTP 410"
    assert Board.stats().total == 0
  end

  test "board updates live when another process changes it", %{conn: conn, wishlist: wishlist} do
    {:ok, view, _html} = live(conn, ~p"/")

    job_fixture(wishlist, %{"company" => "Oban Inc"})

    assert render(view) =~ "Oban Inc"
  end
end
