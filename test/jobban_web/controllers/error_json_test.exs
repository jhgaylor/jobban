defmodule JobbanWeb.ErrorJSONTest do
  use JobbanWeb.ConnCase, async: true

  test "renders 404" do
    assert JobbanWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert JobbanWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
