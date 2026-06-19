# async: false — toggles the global OpenRouter API key + feature flag.
defmodule Jobban.NetworkingTest do
  use Jobban.DataCase, async: false

  import Jobban.BoardFixtures

  alias Jobban.Board
  alias Jobban.Networking

  describe "parse_guide/1" do
    test "keeps targets and trims fields" do
      json = ~s({"targets": [
        {"label": "Hiring manager", "title_hint": " EM, Platform ", "why": "owns the req", "searches": [{"query": "Acme Engineering Manager payments", "platform": "linkedin"}, {"query": " Acme tech recruiter ", "platform": "google"}], "how_to_find": "search LinkedIn", "referral_path": "ask for advice, then a referral"},
        {"label": "Recruiter"}
      ]})

      assert {:ok, [hm, rec]} = Networking.parse_guide(json)
      assert hm.label == "Hiring manager"
      assert hm.title_hint == "EM, Platform"
      assert hm.referral_path == "ask for advice, then a referral"

      assert hm.searches == [
               %{query: "Acme Engineering Manager payments", platform: "linkedin"},
               %{query: "Acme tech recruiter", platform: "google"}
             ]

      assert rec.label == "Recruiter"
      assert rec.how_to_find == nil
      assert rec.referral_path == nil
      assert rec.searches == []
    end

    test "normalizes loose search shapes (bare strings, unknown platform)" do
      json = ~s({"targets": [
        {"label": "IC", "searches": ["just a string", {"query": "x", "platform": "twitter"}, {"query": "  "}]}
      ]})

      assert {:ok, [ic]} = Networking.parse_guide(json)

      assert ic.searches == [
               %{query: "just a string", platform: "linkedin"},
               %{query: "x", platform: "linkedin"}
             ]
    end

    test "rejects payloads without a targets list" do
      assert {:error, :bad_llm_payload} = Networking.parse_guide(~s({"foo": 1}))
      assert {:error, :bad_llm_payload} = Networking.parse_guide(~s({"targets": []}))
      assert {:error, :bad_llm_payload} = Networking.parse_guide("nope")
    end
  end

  describe "parse_draft/1" do
    test "returns linkedin + email parts" do
      json = ~s({"linkedin": " hi ", "email_subject": "Quick q", "email_body": "Body here"})
      assert {:ok, d} = Networking.parse_draft(json)
      assert d.linkedin == "hi"
      assert d.email_subject == "Quick q"
      assert d.email_body == "Body here"
    end

    test "requires a linkedin field" do
      assert {:error, :bad_llm_payload} = Networking.parse_draft(~s({"email_body": "x"}))
    end
  end

  describe "guide/1 and draft/2 (LLM)" do
    setup do
      Application.put_env(:jobban, :openrouter_api_key, "test-key")
      Application.put_env(:jobban, :networking_enabled, true)

      on_exit(fn ->
        Application.put_env(:jobban, :openrouter_api_key, nil)
        Application.put_env(:jobban, :networking_enabled, false)
      end)

      [wishlist | _] = stages_fixture()
      %{job: job_fixture(wishlist)}
    end

    test "guide persists generated targets", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  ~s({"targets": [{"label": "Recruiter", "title_hint": "Tech Recruiter", "why": "easy first touch", "searches": [{"query": "Acme tech recruiter", "platform": "google"}], "how_to_find": "named on the posting"}]})
              }
            }
          ]
        })
      end)

      assert {:ok, _} = Networking.guide(job)

      assert [%{label: "Recruiter", how_to_find: "named on the posting", searches: searches}] =
               Board.get_job!(job.id).networking_targets

      # round-trips through jsonb as string-keyed maps
      assert searches == [%{"query" => "Acme tech recruiter", "platform" => "google"}]
    end

    test "draft returns both channels", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" =>
                  ~s({"linkedin": "Hi there", "email_subject": "Hello", "email_body": "Body"})
              }
            }
          ]
        })
      end)

      assert {:ok, %{linkedin: "Hi there", email_subject: "Hello", email_body: "Body"}} =
               Networking.draft(job, %{label: "Hiring manager", title_hint: "EM"})
    end

    test "disabled without a key", %{job: job} do
      Application.put_env(:jobban, :openrouter_api_key, nil)
      assert {:error, :disabled} = Networking.guide(job)
      assert {:error, :disabled} = Networking.draft(job, %{label: "x"})
    end
  end
end
