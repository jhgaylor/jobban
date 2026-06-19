defmodule JobbanWeb.LaunchpadLiveTest do
  use JobbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Jobban.BoardFixtures

  alias Jobban.Board

  setup do
    [wishlist, applied | _] = stages_fixture()
    %{wishlist: wishlist, applied: applied}
  end

  defp assessment(slug, leverage, steps) do
    %{slug: slug, leverage: leverage, rationale: "because #{slug}", steps: steps}
  end

  test "redirects non-admins back to the board", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/launchpad")
  end

  describe "as admin" do
    setup %{conn: conn} do
      %{conn: log_in_admin(conn)}
    end

    test "renders the queue with listings and their next action", %{
      conn: conn,
      wishlist: wishlist
    } do
      job_fixture(wishlist, %{"company" => "Tailscale", "title" => "Platform Eng"})

      {:ok, _view, html} = live(conn, ~p"/launchpad")

      assert html =~ "Tailscale"
      # an unassessed listing's next move in the queue is to size it up
      assert html =~ "Not assessed yet"
      assert html =~ "Size it up"
    end

    test "queue row surfaces the recommended side door once assessed", %{
      conn: conn,
      wishlist: wishlist
    } do
      job = job_fixture(wishlist, %{"company" => "Tailscale"})
      {:ok, _} = Board.record_assessment(job, [assessment("networking", "high", ["DM the EM"])])

      {:ok, _view, html} = live(conn, ~p"/launchpad")

      assert html =~ "Side door"
      assert html =~ "Networking"
    end

    test "opening a listing shows the full checklist (always visible)", %{
      conn: conn,
      wishlist: wishlist
    } do
      job = job_fixture(wishlist)

      {:ok, _} =
        Board.record_assessment(job, [assessment("networking", "high", ["Ask Dana", "DM the EM"])])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      # checklist is not collapsed — both steps + the play rationale show on open
      html = view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      assert html =~ "The plan"
      assert html =~ "Networking"
      assert html =~ "Ask Dana"
      assert html =~ "DM the EM"
      assert html =~ "because networking"
    end

    test "completed steps stay visible and can be un-checked", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("build", "high", ["Ship a demo"])])
      task = hd(Board.get_job!(job.id).tasks)
      {:ok, _} = Board.toggle_task(task)

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      # the done step is still on screen (not hidden behind "do this next")
      html = view |> element("button[phx-value-id='#{job.id}']") |> render_click()
      assert html =~ "Ship a demo"

      # un-check it
      render_hook(view, "toggle_task", %{"id" => to_string(task.id)})
      refute Board.get_task!(task.id).done
    end

    test "leads with a 'do this next' action", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)

      {:ok, _} =
        Board.record_assessment(job, [assessment("build", "high", ["Ship a quick demo"])])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      html = view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      # the lead card is always visible (not collapsed) and names the next step + why
      assert html =~ "Do this next"
      assert html =~ "Ship a quick demo"
      assert html =~ "high leverage"
    end

    test "leads with 'find people' when networking is top and unmapped", %{
      conn: conn,
      wishlist: wishlist
    } do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("networking", "high", ["intro"])])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      html = view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      assert html =~ "Do this next"
      assert html =~ "map out who to reach"
    end

    test "toggling a generated step persists", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("build", "high", ["Ship a demo"])])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      task = hd(Board.get_job!(job.id).tasks)
      render_hook(view, "toggle_task", %{"id" => to_string(task.id)})

      assert Board.get_task!(task.id).done
    end

    test "adding a freeform step persists", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      render_hook(view, "add_task", %{"task" => %{"title" => "Cold email the CTO"}})

      assert Enum.any?(Board.get_job!(job.id).tasks, &(&1.title == "Cold email the CTO"))
    end

    test "shows generated networking targets with how-to-find", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)

      {:ok, _} =
        Board.record_networking_targets(job, [
          %{
            label: "Hiring manager",
            title_hint: "EM, Platform",
            why: "owns the req",
            how_to_find: "Filter the company People tab by 'engineering manager'",
            referral_path: "Ask for 15 min of advice, then ask them to flag your app"
          }
        ])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("button[phx-value-id='#{job.id}']") |> render_click()
      html = render_hook(view, "toggle_section", %{"section" => "people"})

      assert html =~ "Who to reach"
      assert html =~ "Hiring manager"
      assert html =~ "EM, Platform"
      assert html =~ "Filter the company People tab"
      assert html =~ "Turn it into a referral"
      assert html =~ "Ask for 15 min of advice"
    end

    test "shows a generated briefing", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)

      {:ok, _} =
        Board.record_brief(job, %{
          company_overview: "They run payments infrastructure.",
          role_in_company: "Sits on the platform team.",
          strategic_value: "Directly protects revenue."
        })

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("button[phx-value-id='#{job.id}']") |> render_click()
      html = render_hook(view, "toggle_section", %{"section" => "briefing"})

      assert html =~ "Size it up"
      assert html =~ "They run payments infrastructure."
      assert html =~ "Why it matters to them"
      assert html =~ "Directly protects revenue."
    end

    test "adding a contact persists and shows up", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      render_hook(view, "add_contact", %{
        "contact" => %{"name" => "Dana Reed", "role" => "Recruiter"}
      })

      assert [%{name: "Dana Reed"}] = Board.get_job!(job.id).contacts
      html = render_hook(view, "toggle_section", %{"section" => "people"})
      assert html =~ "Dana Reed"
    end
  end
end
