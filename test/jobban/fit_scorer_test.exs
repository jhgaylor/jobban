# async: false — these tests toggle the global OpenRouter API key, which the
# (async) importer tests rely on being absent.
defmodule Jobban.FitScorerTest do
  use Jobban.DataCase, async: false

  import Jobban.BoardFixtures

  alias Jobban.Board
  alias Jobban.FitScorer

  describe "parse/1" do
    test "accepts a well-formed payload" do
      assert {:ok, 4, "Strong infra match."} =
               FitScorer.parse(~s({"score": 4, "summary": "Strong infra match."}))
    end

    test "tolerates a missing summary" do
      assert {:ok, 2, nil} = FitScorer.parse(~s({"score": 2}))
    end

    test "rejects out-of-range, non-integer, and malformed payloads" do
      assert {:error, :bad_llm_payload} = FitScorer.parse(~s({"score": 7, "summary": "x"}))
      assert {:error, :bad_llm_payload} = FitScorer.parse(~s({"score": "4"}))
      assert {:error, :bad_llm_payload} = FitScorer.parse("not json")
    end
  end

  describe "score/1" do
    setup do
      Application.put_env(:jobban, :openrouter_api_key, "test-key")
      on_exit(fn -> Application.put_env(:jobban, :openrouter_api_key, nil) end)

      [wishlist | _] = stages_fixture()
      %{job: job_fixture(wishlist)}
    end

    test "records score, summary, and an activity from the LLM verdict", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [
            %{
              "message" => %{
                "content" => ~s({"score": 5, "summary": "Bullseye: staff platform role."})
              }
            }
          ]
        })
      end)

      assert {:ok, scored} = FitScorer.score(job)
      assert scored.fit_score == 5
      assert scored.fit_summary == "Bullseye: staff platform role."
      assert scored.fit_scored_at

      activities = Board.get_job!(job.id).activities
      assert Enum.any?(activities, &(&1.kind == "scored" and &1.body =~ "5/5"))
    end

    test "leaves the job unscored when the LLM returns junk", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => "not the JSON you asked for"}}]
        })
      end)

      assert {:error, :not_scored} = FitScorer.score(job)
      assert Board.get_job!(job.id).fit_score == nil
    end

    test "scoring a deleted job is a clean no-op", %{job: job} do
      Req.Test.stub(Jobban.LLM.OpenRouter, fn conn ->
        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => ~s({"score": 3, "summary": "ok"})}}]
        })
      end)

      {:ok, _} = Board.delete_job(Board.get_job!(job.id))
      assert {:error, :job_deleted} = FitScorer.score(job)
    end
  end

  describe "jobs_missing_fit/0" do
    test "returns only unscored jobs" do
      [wishlist | _] = stages_fixture()
      unscored = job_fixture(wishlist, %{"company" => "A"})
      scored = job_fixture(wishlist, %{"company" => "B"})

      {:ok, _} = Board.record_fit(scored, 4, "good")

      ids = Enum.map(Board.jobs_missing_fit(), & &1.id)
      assert unscored.id in ids
      refute scored.id in ids
    end
  end
end
