# async: false — toggles the global OpenRouter API key + feature flag, which
# the (async) importer/scorer tests rely on being absent/off.
defmodule Jobban.WayInSuggesterTest do
  use Jobban.DataCase, async: false

  import Jobban.BoardFixtures

  alias Jobban.WayInSuggester

  describe "parse/1" do
    test "accepts approach plus steps" do
      assert {:ok, %{approach: "Go through Dana.", steps: ["Message Dana", "Tailor resume"]}} =
               WayInSuggester.parse(
                 ~s({"approach": "Go through Dana.", "steps": ["Message Dana", " Tailor resume "]})
               )
    end

    test "tolerates missing or non-list steps" do
      assert {:ok, %{approach: "Apply directly.", steps: []}} =
               WayInSuggester.parse(~s({"approach": "Apply directly."}))

      assert {:ok, %{steps: []}} =
               WayInSuggester.parse(~s({"approach": "x", "steps": "nope"}))
    end

    test "rejects payloads with no approach" do
      assert {:error, :bad_llm_payload} = WayInSuggester.parse(~s({"steps": ["a"]}))
      assert {:error, :bad_llm_payload} = WayInSuggester.parse("not json")
    end
  end

  describe "suggest/1" do
    setup do
      Application.put_env(:jobban, :openrouter_api_key, "test-key")
      Application.put_env(:jobban, :way_in_suggester_enabled, true)

      on_exit(fn ->
        Application.put_env(:jobban, :openrouter_api_key, nil)
        Application.put_env(:jobban, :way_in_suggester_enabled, false)
      end)

      [wishlist | _] = stages_fixture()
      %{job: job_fixture(wishlist)}
    end

    test "returns a drafted way in from the LLM verdict", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" => ~s({"approach": "Warm intro via Dana.", "steps": ["DM Dana"]})
              }
            }
          ]
        })
      end)

      assert {:ok, %{approach: "Warm intro via Dana.", steps: ["DM Dana"]}} =
               WayInSuggester.suggest(job)
    end

    test "fails cleanly on junk", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "nope"}}]})
      end)

      assert {:error, :not_suggested} = WayInSuggester.suggest(job)
    end

    test "is disabled without a key", %{job: job} do
      Application.put_env(:jobban, :openrouter_api_key, nil)
      assert {:error, :disabled} = WayInSuggester.suggest(job)
    end
  end
end
