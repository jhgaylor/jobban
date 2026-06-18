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

    test "renders the matrix with play columns and listings", %{conn: conn, wishlist: wishlist} do
      job_fixture(wishlist, %{"company" => "Tailscale", "title" => "Platform Eng"})

      {:ok, _view, html} = live(conn, ~p"/launchpad")

      assert html =~ "Tailscale"
      for col <- ~w(Net Pitch Build Blog Apply), do: assert(html =~ col)
    end

    test "opening a listing shows its plays and rationales", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("networking", "high", ["Ask Dana"])])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      html = view |> element("tr[phx-value-id='#{job.id}']") |> render_click()

      assert html =~ "Networking"
      assert html =~ "Ask Dana"
      assert html =~ "because networking"
    end

    test "toggling a generated step persists", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, _} = Board.record_assessment(job, [assessment("build", "high", ["Ship a demo"])])

      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("tr[phx-value-id='#{job.id}']") |> render_click()

      task = hd(Board.get_job!(job.id).tasks)
      render_hook(view, "toggle_task", %{"id" => to_string(task.id)})

      assert Board.get_task!(task.id).done
    end

    test "adding a freeform step persists", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("tr[phx-value-id='#{job.id}']") |> render_click()

      render_hook(view, "add_task", %{"task" => %{"title" => "Cold email the CTO"}})

      assert Enum.any?(Board.get_job!(job.id).tasks, &(&1.title == "Cold email the CTO"))
    end

    test "adding a contact persists and shows up", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")
      view |> element("tr[phx-value-id='#{job.id}']") |> render_click()

      render_hook(view, "add_contact", %{
        "contact" => %{"name" => "Dana Reed", "role" => "Recruiter"}
      })

      assert [%{name: "Dana Reed"}] = Board.get_job!(job.id).contacts
      assert render(view) =~ "Dana Reed"
    end
  end
end
