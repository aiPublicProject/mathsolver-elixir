defmodule MathsolverTest do
  use ExUnit.Case, async: true

  # v0.2 protocol fixtures: the model returns program/steps/check — never an answer.
  @good Jason.encode!(%{program: "let d = 11 - 3;\nlet x = d / 2;\nresult = x", steps: ["Subtract 3: 2x = 8", "Divide by 2: x = 4"], check: "2*{x} + 3 - 11"})
  @no_check Jason.encode!(%{program: "result = 0.15 * 80", steps: ["Compute 15% of 80"]})
  @wrong_check Jason.encode!(%{program: "let d = 11 - 3;\nresult = d / 2", steps: ["..."], check: "2*{x} + 3 - 12"})
  @broken_program Jason.encode!(%{program: "result = undefinedvar + 1", steps: []})

  test "evaluator precedence" do
    assert_in_delta Mathsolver.eval_expression("2*3+4"), 10, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("2+3*4"), 14, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("(2+3)*4"), 20, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("2^3^2"), 512, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("-3^2"), -9, 1.0e-9
  end

  test "evaluator functions" do
    assert_in_delta Mathsolver.eval_expression("sqrt(16)"), 4, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("min(3,5)"), 3, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("pi"), :math.pi(), 1.0e-12
    assert_in_delta Mathsolver.eval_expression("log(1000)"), 3, 1.0e-9
  end

  test "evaluator env variables" do
    assert_in_delta Mathsolver.eval_expression("d / 2", %{"d" => 8.0}), 4, 1.0e-9
    assert_in_delta Mathsolver.eval_expression("x + y", %{"x" => 1.5, "y" => 2.5}), 4, 1.0e-9
    assert_raise Mathsolver.Error, fn -> Mathsolver.eval_expression("d") end
    assert_in_delta Mathsolver.eval_expression("pi", %{"pi" => 3.0}), 3, 1.0e-12
  end

  test "evaluator rejects bad input" do
    for bad <- ["System.cmd(\"x\")", "1+2)", "foo(1)", ""] do
      assert_raise Mathsolver.Error, fn -> Mathsolver.eval_expression(bad) end
    end
  end

  test "run_program executes let/result/bare" do
    assert_in_delta Mathsolver.run_program("let d = 11 - 3;\nlet x = d / 2;\nresult = x"), 4, 1.0e-9
    assert_in_delta Mathsolver.run_program("let a = 3; let b = 4; a * b"), 12, 1.0e-9
    assert_in_delta Mathsolver.run_program("0.15 * 80"), 12, 1.0e-9
    for bad <- ["result = undefinedvar + 1", "", "let a = 1; let b = 2"] do
      assert_raise Mathsolver.Error, fn -> Mathsolver.run_program(bad) end
    end
  end

  test "run_check substitutes {x}" do
    pass = Mathsolver.run_check("2*{x} + 3 - 11", 4.0)
    assert pass.passed
    assert_in_delta pass.value, 0, 1.0e-9
    fail = Mathsolver.run_check("2*{x} + 3 - 12", 4.0)
    refute fail.passed
    assert_in_delta fail.value, -1, 1.0e-9
    assert Mathsolver.run_check("80*15/100 - {x}", 12.0).passed
  end

  test "new validates credentials" do
    assert {:error, {:"NO_API_KEY", _}} = Mathsolver.new(api_key: "")
    assert {:error, {:"BAD_BASE_URL", _}} = Mathsolver.new(api_key: "sk", base_url: "not-a-url")
  end

  test "answer comes from program execution, verified first try" do
    {:ok, agent} = Agent.start_link(fn -> %{calls: 0, url: nil, key: nil, body: nil} end)

    tr = fn url, body, key ->
      Agent.update(agent, fn s -> %{s | calls: s.calls + 1, url: url, key: key, body: Jason.decode!(body)} end)
      {:ok, @good}
    end

    {:ok, solver} = Mathsolver.new(api_key: "sk-test", base_url: "https://api.deepseek.com/v1", model: "deepseek-chat", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x + 3 = 11, solve for x")
    # 答案=执行产物(4), 代回检验=0; 模型 JSON 里没有 answer 字段
    assert r.verified
    assert_in_delta r.answer, 4, 1.0e-9
    assert r.retries == 0
    assert_in_delta r.check_value, 0, 1.0e-9
    state = Agent.get(agent, & &1)
    assert state.calls == 1
    assert state.url == "https://api.deepseek.com/v1/chat/completions"
    assert state.key == "sk-test"
    assert state.body["model"] == "deepseek-chat"
    assert state.body["temperature"] == 0
    refute Map.has_key?(Jason.decode!(@good), "answer")
  end

  test "no check -> unverified, answer from execution" do
    tr = fn _u, _b, _k -> {:ok, @no_check} end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "15% of 80")
    assert_in_delta r.answer, 12, 1.0e-9
    refute r.verified
    assert is_nil(r.check)
    assert is_nil(r.check_value)
  end

  test "check fails -> retry recovers" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    tr = fn _u, _b, _k ->
      n = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      {:ok, if(n == 1, do: @wrong_check, else: @good)}
    end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x+3=11")
    assert r.verified
    assert r.retries == 1
    assert_in_delta r.answer, 4, 1.0e-9
  end

  test "program error -> retry recovers" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    tr = fn _u, _b, _k ->
      n = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      {:ok, if(n == 1, do: @broken_program, else: @good)}
    end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x+3=11")
    assert r.verified
    assert_in_delta r.answer, 4, 1.0e-9
  end

  test "program error persists -> PROGRAM_/EXPR_ error" do
    tr = fn _u, _b, _k -> {:ok, @broken_program} end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    assert {:error, {code, _}} = Mathsolver.solve(solver, "2x+3=11")
    assert to_string(code) =~ ~r/^(PROGRAM_|EXPR_)/
  end

  test "invalid json then ok" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    tr = fn _u, _b, _k ->
      n = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      {:ok, if(n == 1, do: "no json", else: @good)}
    end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "1+1")
    assert r.verified
  end

  test "invalid twice raises" do
    tr = fn _u, _b, _k -> {:ok, "nothing"} end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    assert {:error, {:"INVALID_JSON", _}} = Mathsolver.solve(solver, "1+1")
  end

  test "http error no retry" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    tr = fn _u, _b, _k ->
      Agent.update(agent, &(&1 + 1))
      {:error, {:"HTTP_ERROR", "401"}}
    end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    assert {:error, {:"HTTP_ERROR", _}} = Mathsolver.solve(solver, "1+1")
    assert Agent.get(agent, & &1) == 1
  end

  test "check still failing after retry -> unverified, answer kept" do
    tr = fn _u, _b, _k -> {:ok, @wrong_check} end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x+3=11")
    assert_in_delta r.answer, 4, 1.0e-9
    refute r.verified
    assert r.retries == 1
  end

  # HTTP-interface mock: inject an http_post seam so the DEFAULT transport runs
  # its real code path (URL, headers, body, status, envelope parsing) against
  # synthetic OpenAI-shaped responses. No server, no sockets.
  defp mocked_solver(api_key, contents, statuses \\ []) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    solver =
      Mathsolver.new!(
        api_key: api_key,
        base_url: "https://mock.test/v1",
        model: "mock-model",
        http_post: fn url, headers, body ->
          n = length(Agent.get(agent, & &1))
          content = Enum.at(contents, n) || @good
          status = Enum.at(statuses, n) || 0
          Agent.update(agent, fn calls ->
            [%{url: url, headers: Map.new(headers), body: Jason.decode!(body)} | calls]
          end)
          if status >= 300 do
            {:ok, {status, "upstream boom"}}
          else
            {:ok, {200, Jason.encode!(%{choices: [%{message: %{content: content}}]})}}
          end
        end
      )

    {solver, agent}
  end

  test "http mock: full round trip via default transport" do
    {solver, agent} = mocked_solver("sk-mock", [@good])
    {:ok, r} = Mathsolver.solve(solver, "2x + 3 = 11, solve for x")
    assert r.verified
    assert r.retries == 0
    assert_in_delta r.answer, 4, 1.0e-9
    calls = Agent.get(agent, & &1) |> Enum.reverse()
    assert length(calls) == 1
    call = hd(calls)
    assert call.url == "https://mock.test/v1/chat/completions"
    assert call.headers["authorization"] == "Bearer sk-mock"
    assert call.body["model"] == "mock-model"
    assert call.body["temperature"] == 0
    assert hd(call.body["messages"])["role"] == "system"
    assert hd(call.body["messages"])["content"] =~ "STRICT JSON"
  end

  test "http mock: check fails -> corrective retry carries reason" do
    {solver, agent} = mocked_solver("sk", [@wrong_check, @good])
    {:ok, r} = Mathsolver.solve(solver, "2x+3=11")
    assert r.verified
    assert r.retries == 1
    calls = Agent.get(agent, & &1) |> Enum.reverse()
    assert length(calls) == 2
    retry_call = Enum.at(calls, 1)
    assert Enum.any?(retry_call.body["messages"], &String.contains?(&1["content"], "failed verification"))
  end

  test "http mock: invalid json re-ask" do
    {solver, agent} = mocked_solver("sk", ["certainly not json", @good])
    {:ok, r} = Mathsolver.solve(solver, "1+1")
    assert r.verified
    assert length(Agent.get(agent, & &1)) == 2
  end

  test "http mock: 500 -> HTTP_ERROR no retry" do
    {solver, agent} = mocked_solver("sk", [], [500])
    assert {:error, {:"HTTP_ERROR", _}} = Mathsolver.solve(solver, "1+1")
    assert length(Agent.get(agent, & &1)) == 1
  end

  test "http mock: 401 -> HTTP_ERROR" do
    {solver, _} = mocked_solver("sk-bad", [], [401])
    assert {:error, {:"HTTP_ERROR", _}} = Mathsolver.solve(solver, "1+1")
  end

  @tag :smoke
  test "smoke: real API round-trip" do
    key = System.get_env("SMOKE_API_KEY")

    if key do
      base = System.get_env("SMOKE_BASE_URL") || "https://api.openai.com/v1"
      {:ok, solver} = Mathsolver.new(api_key: key, base_url: base)
      {:ok, r} = Mathsolver.solve(solver, "2x + 3 = 11, solve for x")
      IO.puts("smoke: answer=#{inspect(r.answer)} verified=#{inspect(r.verified)} retries=#{inspect(r.retries)}")
      assert r.verified
      assert_in_delta r.answer, 4, 1.0e-9
    end
    # 无 key 静默通过;smoke.yml Require-secret 步骤保证触发时必有 key
  end
end
