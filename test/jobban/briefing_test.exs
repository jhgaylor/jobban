# async: false — toggles the global OpenRouter API key + feature flag.
defmodule Jobban.BriefingTest do
  use Jobban.DataCase, async: false

  import Jobban.BoardFixtures

  alias Jobban.Board
  alias Jobban.Briefing

  describe "parse/1" do
    test "returns the three sections, trimmed" do
      json =
        ~s({"company_overview": " They sell X ", "role_in_company": "Owns Y", "strategic_value": "Drives Z"})

      assert {:ok, attrs} = Briefing.parse(json)
      assert attrs.company_overview == "They sell X"
      assert attrs.role_in_company == "Owns Y"
      assert attrs.strategic_value == "Drives Z"
    end

    test "tolerates partial payloads" do
      assert {:ok, %{company_overview: "Just this", role_in_company: nil, strategic_value: nil}} =
               Briefing.parse(~s({"company_overview": "Just this"}))
    end

    test "rejects empty / non-json" do
      assert {:error, :bad_llm_payload} = Briefing.parse(~s({"company_overview": "  "}))
      assert {:error, :bad_llm_payload} = Briefing.parse("nope")
    end
  end

  describe "brief/1 (LLM)" do
    setup do
      Application.put_env(:jobban, :openrouter_api_key, "test-key")
      Application.put_env(:jobban, :briefing_enabled, true)

      on_exit(fn ->
        Application.put_env(:jobban, :openrouter_api_key, nil)
        Application.put_env(:jobban, :briefing_enabled, false)
      end)

      [wishlist | _] = stages_fixture()
      %{job: job_fixture(wishlist)}
    end

    test "generates and persists the briefing", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  ~s({"company_overview": "Payments infra.", "role_in_company": "On the platform team.", "strategic_value": "Keeps revenue flowing."})
              }
            }
          ]
        })
      end)

      assert {:ok, _} = Briefing.brief(job)
      brief = Board.get_job!(job.id).job_brief
      assert brief.company_overview == "Payments infra."
      assert brief.strategic_value == "Keeps revenue flowing."
      assert brief.generated_at
    end

    test "disabled without a key", %{job: job} do
      Application.put_env(:jobban, :openrouter_api_key, nil)
      assert {:error, :disabled} = Briefing.brief(job)
    end
  end
end
