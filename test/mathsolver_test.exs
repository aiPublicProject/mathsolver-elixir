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

  test "solve verified first try" do
    {:ok, agent} = Agent.start_link(fn -> %{calls: 0, url: nil, key: nil} end)

    tr = fn url, _body, key ->
      Agent.update(agent, fn s -> %{s | calls: s.calls + 1, url: url, key: key} end)
      {:ok, @good}
    end

    r = Mathsolver.solve("2x + 3 = 11, solve for x", api_key: "sk-test", transport: tr)
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

    r = Mathsolver.solve("2x+3=11", api_key: "sk", transport: tr)
    assert r.verified
    assert r.retries == 1
  end

  test "invalid json then ok" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    tr = fn _u, _b, _k ->
      n = Agent.get_and_update(agent, fn n -> {n + 1, n + 1} end)
      {:ok, if(n == 1, do: "no json", else: @good)}
    end

    r = Mathsolver.solve("1+1", api_key: "sk", transport: tr)
    assert r.verified
  end

  test "invalid twice raises" do
    tr = fn _u, _b, _k -> {:ok, "nothing"} end
    assert_raise Mathsolver, fn -> Mathsolver.solve("1+1", api_key: "sk", transport: tr) end
  end

  test "no api key raises" do
    assert_raise Mathsolver, fn -> Mathsolver.solve("1+1", []) end
  end

  test "http error no retry" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    tr = fn _u, _b, _k ->
      Agent.update(agent, fn n -> n + 1 end)
      {:error, {:"HTTP_ERROR", "401"}}
    end

    assert_raise Mathsolver, fn -> Mathsolver.solve("1+1", api_key: "sk", transport: tr) end
    assert Agent.get(agent, & &1) == 1
  end

  test "still wrong unverified" do
    tr = fn _u, _b, _k -> {:ok, @wrong} end
    r = Mathsolver.solve("2x+3=11", api_key: "sk", transport: tr)
    refute r.verified
    assert r.retries == 1
  end
end
