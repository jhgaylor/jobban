defmodule JobbanWeb.AuthControllerTest do
  use JobbanWeb.ConnCase, async: true

  # In prod the ingress wraps /login in the SSO forwardAuth middleware,
  # which overwrites x-auth-request-user with the verified GitHub login.
  # Here we play the proxy's part.
  describe "GET /login" do
    test "trusted proxy header grants the admin session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-auth-request-user", "jhgaylor")
        |> get(~p"/login")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :admin) == true
    end

    test "a different github user is rejected", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-auth-request-user", "mallory")
        |> get(~p"/login")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :admin)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't vouch"
    end

    test "no header at all is rejected", %{conn: conn} do
      conn = get(conn, ~p"/login")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :admin)
    end

    test "redirects home when already logged in", %{conn: conn} do
      conn = conn |> log_in_admin() |> get(~p"/login")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "DELETE /logout" do
    test "drops the admin session", %{conn: conn} do
      conn = conn |> log_in_admin() |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :admin)
    end
  end
end
