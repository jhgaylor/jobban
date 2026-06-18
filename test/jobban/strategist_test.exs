# async: false — toggles the global OpenRouter API key + feature flag, which
# the (async) importer/scorer tests rely on being absent/off.
defmodule Jobban.StrategistTest do
  use Jobban.DataCase, async: false

  import Jobban.BoardFixtures

  alias Jobban.Board
  alias Jobban.Strategist

  describe "parse/1" do
    test "keeps catalog plays and normalizes leverage + steps" do
      json = ~s({"plays": [
        {"slug": "networking", "leverage": "high", "rationale": "warm path", "steps": [" Ask Dana ", ""]},
        {"slug": "apply", "leverage": "skip", "rationale": "last resort", "steps": []}
      ]})

      assert {:ok, plays} = Strategist.parse(json)
      net = Enum.find(plays, &(&1.slug == "networking"))
      assert net.leverage == "high"
      assert net.steps == ["Ask Dana"]
      assert Enum.find(plays, &(&1.slug == "apply")).leverage == "skip"
    end

    test "drops unknown plays and bad leverage falls back to skip" do
      json = ~s({"plays": [
        {"slug": "bribery", "leverage": "high", "steps": ["no"]},
        {"slug": "blog", "leverage": "enormous", "steps": ["write"]}
      ]})

      assert {:ok, [%{slug: "blog", leverage: "skip"}]} = Strategist.parse(json)
    end

    test "rejects payloads without a plays list" do
      assert {:error, :bad_llm_payload} = Strategist.parse(~s({"foo": 1}))
      assert {:error, :bad_llm_payload} = Strategist.parse("not json")
      assert {:error, :bad_llm_payload} = Strategist.parse(~s({"plays": []}))
    end
  end

  describe "assess/1" do
    setup do
      Application.put_env(:jobban, :openrouter_api_key, "test-key")
      Application.put_env(:jobban, :strategist_enabled, true)

      on_exit(fn ->
        Application.put_env(:jobban, :openrouter_api_key, nil)
        Application.put_env(:jobban, :strategist_enabled, false)
      end)

      [wishlist | _] = stages_fixture()
      %{job: job_fixture(wishlist)}
    end

    test "records the assessment and generates steps from the LLM verdict", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" => ~s({"plays": [
                  {"slug": "build", "leverage": "high", "rationale": "they ship", "steps": ["Build a demo"]},
                  {"slug": "apply", "leverage": "skip", "steps": []}
                ]})
              }
            }
          ]
        })
      end)

      assert {:ok, _} = Strategist.assess(job)

      reloaded = Board.get_job!(job.id)
      assert Enum.find(reloaded.job_plays, &(&1.slug == "build")).leverage == "high"
      assert Enum.any?(reloaded.tasks, &(&1.title == "Build a demo" and &1.play_slug == "build"))
    end

    test "leaves the job unassessed when the LLM returns junk", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => "garbage"}}]})
      end)

      assert {:error, :not_assessed} = Strategist.assess(job)
      assert Board.get_job!(job.id).job_plays == []
    end

    test "is disabled without a key", %{job: job} do
      Application.put_env(:jobban, :openrouter_api_key, nil)
      assert {:error, :not_assessed} = Strategist.assess(job)
    end
  end
end
