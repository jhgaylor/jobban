defmodule JobbanWeb.Auth do
  @moduledoc """
  Admin auth via the cluster's GitHub SSO proxy — no passwords, no user
  records.

  The board is publicly readable. `/login` is the only route the Traefik
  IngressRoute wraps in the oauth2-proxy forwardAuth middlewares; requests
  reaching it have already been authenticated against GitHub, and Traefik
  overwrites `x-auth-request-user` with the verified login (client-supplied
  values can't survive the middleware). We compare it to the configured
  GitHub user and flip a session flag for write access.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @doc """
  Whether the request carries the trusted proxy header for the configured
  GitHub login.

  Fails closed when no user is configured. In dev there is no proxy in
  front of localhost, so `auth_bypass: true` makes this always pass.
  """
  def authorized?(conn) do
    if Application.get_env(:jobban, :auth_bypass, false) do
      true
    else
      case Application.get_env(:jobban, :github_user) do
        user when is_binary(user) and user != "" ->
          get_req_header(conn, "x-auth-request-user") == [user]

        _ ->
          false
      end
    end
  end

  @doc "Whether the LiveView session carries the admin flag."
  def admin_session?(session), do: session["admin"] == true
end
