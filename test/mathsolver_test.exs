defmodule MathsolverTest do
  use ExUnit.Case, async: true

  @good Jason.encode!(%{answer: 4, steps: ["Subtract 3: 2x = 8", "Divide by 2: x = 4"], verification: %{expression: "(11-3)/2"}})
  @wrong Jason.encode!(%{answer: 4, steps: ["..."], verification: %{expression: "(11-3)/3"}})

  test "evaluator precedence" do
    assert_in_delta Mathsolver.eval_expression("2*3+4"), 10, 1e-9
    assert_in_delta Mathsolver.eval_expression("2+3*4"), 14, 1e-9
    assert_in_delta Mathsolver.eval_expression("(2+3)*4"), 20, 1e-9
    assert_in_delta Mathsolver.eval_expression("2^3^2"), 512, 1e-9
    assert_in_delta Mathsolver.eval_expression("-3^2"), -9, 1e-9
  end

  test "evaluator functions" do
    assert_in_delta Mathsolver.eval_expression("sqrt(16)"), 4, 1e-9
    assert_in_delta Mathsolver.eval_expression("min(3,5)"), 3, 1e-9
    assert_in_delta Mathsolver.eval_expression("pi"), :math.pi(), 1e-12
    assert_in_delta Mathsolver.eval_expression("log(1000)"), 3, 1e-9
  end

  test "evaluator rejects bad input" do
    for bad <- ["System.cmd(\"x\")", "1+2)", "foo(1)", ""] do
      assert_raise Mathsolver, fn -> Mathsolver.eval_expression(bad) end
    end
  end

  test "new validates credentials" do
    assert {:error, {:"NO_API_KEY", _}} = Mathsolver.new(api_key: "")
    assert {:error, {:"BAD_BASE_URL", _}} = Mathsolver.new(api_key: "sk", base_url: "not-a-url")
  end

  test "solve verified first try" do
    {:ok, agent} = Agent.start_link(fn -> %{calls: 0, url: nil, key: nil} end)

    tr = fn url, _body, key ->
      Agent.update(agent, fn s -> %{s | calls: s.calls + 1, url: url, key: key} end)
      {:ok, @good}
    end

    {:ok, solver} = Mathsolver.new(api_key: "sk-test", base_url: "https://api.deepseek.com/v1", model: "deepseek-chat", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x + 3 = 11, solve for x")
    assert r.verified
    assert r.answer == 4
    assert r.evaluated == 4
    assert r.retries == 0
    state = Agent.get(agent, & &1)
    assert state.calls == 1
    assert String.ends_with?(state.url, "/chat/completions")
    assert state.key == "sk-test"
  end

  test "solve retry recovers" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    tr = fn _u, _b, _k ->
      n = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      {:ok, if(n == 1, do: @wrong, else: @good)}
    end

    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x+3=11")
    assert r.verified
    assert r.retries == 1
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

  test "invalid twice returns error" do
    tr = fn _u, _b, _k -> {:ok, "nothing"} end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    assert {:error, {:"INVALID_JSON", _}} = Mathsolver.solve(solver, "1+1")
  end

  test "no api key fails at new" do
    assert {:error, {:"NO_API_KEY", _}} = Mathsolver.new(api_key: "")
  end

  test "http error no retry" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    tr = fn _u, _b, _k ->
      Agent.update(agent, fn n -> n + 1 end)
      {:error, {:"HTTP_ERROR", "401"}}
    end

    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    assert {:error, {:"HTTP_ERROR", _}} = Mathsolver.solve(solver, "1+1")
    assert Agent.get(agent, & &1) == 1
  end

  test "still wrong unverified" do
    tr = fn _u, _b, _k -> {:ok, @wrong} end
    {:ok, solver} = Mathsolver.new(api_key: "sk", transport: tr)
    {:ok, r} = Mathsolver.solve(solver, "2x+3=11")
    refute r.verified
    assert r.retries == 1
  end
end
