defmodule JobbanWeb.LaunchpadLiveTest do
  use JobbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Jobban.BoardFixtures

  alias Jobban.Board

  setup do
    [wishlist, applied | _] = stages_fixture()
    %{wishlist: wishlist, applied: applied}
  end

  test "redirects non-admins back to the board", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/launchpad")
  end

  describe "as admin" do
    setup %{conn: conn} do
      %{conn: log_in_admin(conn)}
    end

    test "lists wishlist jobs with the next step", %{conn: conn, wishlist: wishlist} do
      job_fixture(wishlist, %{"company" => "Tailscale", "title" => "Platform Eng"})

      {:ok, _view, html} = live(conn, ~p"/launchpad")

      assert html =~ "Tailscale"
      assert html =~ "Next"
      # first standard step
      assert html =~ "Write the way-in"
    end

    test "opening a job shows its checklist and toggling a task persists", %{
      conn: conn,
      wishlist: wishlist
    } do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")

      view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      task = hd(Board.get_job!(job.id).tasks)
      render_hook(view, "toggle_task", %{"id" => to_string(task.id)})

      assert Board.get_task!(task.id).done
    end

    test "saving the way-in updates the job", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")

      view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      render_hook(view, "save_way_in", %{"job" => %{"approach" => "Ping Dana for a referral."}})

      assert Board.get_job!(job.id).approach == "Ping Dana for a referral."
    end

    test "adding a contact persists and shows up", %{conn: conn, wishlist: wishlist} do
      job = job_fixture(wishlist)
      {:ok, view, _html} = live(conn, ~p"/launchpad")

      view |> element("button[phx-value-id='#{job.id}']") |> render_click()

      render_hook(view, "add_contact", %{
        "contact" => %{"name" => "Dana Reed", "role" => "Recruiter"}
      })

      assert [%{name: "Dana Reed"}] = Board.get_job!(job.id).contacts
      # the {:board_changed} broadcast reloads the worklist + open detail panel
      assert render(view) =~ "Dana Reed"
    end
  end
end
