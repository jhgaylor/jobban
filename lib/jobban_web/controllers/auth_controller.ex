defmodule JobbanWeb.AuthController do
  use JobbanWeb, :controller

  alias JobbanWeb.Auth

  # The ingress sends this route through GitHub SSO before it reaches us,
  # so arriving here authorized just means "set the session and go home".
  def new(conn, _params) do
    cond do
      get_session(conn, :admin) ->
        redirect(conn, to: ~p"/")

      Auth.authorized?(conn) ->
        conn
        |> configure_session(renew: true)
        |> put_session(:admin, true)
        |> put_flash(:info, "Welcome back")
        |> redirect(to: ~p"/")

      true ->
        # Only reachable if the SSO middleware isn't in front of /login
        # (local prod build, ingress misconfig) — fail closed.
        conn
        |> put_flash(:error, "GitHub SSO didn't vouch for you")
        |> redirect(to: ~p"/")
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> delete_session(:admin)
    |> redirect(to: ~p"/")
  end
end
