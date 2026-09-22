defmodule Mathsolver do
  @moduledoc """
  BYOK AI math solver with independent verification.
  An answer is only `verified: true` when the model's verification
  expression (pure arithmetic) is evaluated locally and matches.
  """

  @system_prompt """
  You are a precise math solver.
  Reply with STRICT JSON only, no markdown fences, in this exact shape:
  {"answer": <number>, "steps": [<string>, ...], "verification": {"expression": "<string>"}}
  Rules:
  - "answer" must be a single number (the final result).
  - "steps" must be an array of short plain-language explanation strings.
  - "verification.expression" must be a pure arithmetic expression that
    evaluates to the answer. Allowed: numbers, + - * / % ^ ( ), and the
    functions abs sqrt sin cos tan ln log exp floor ceil round min max
    (log is base 10, ln is natural), and the constants pi and e.
  - The expression must recompute the answer independently.
  """

  defexception [:code, :message]

  @impl true
  def exception({code, message}) when is_atom(code) do
    %__MODULE__{code: code, message: message}
  end

  @funcs %{
    "abs" => {:erlang, :abs},
    "sqrt" => {:math, :sqrt},
    "sin" => {:math, :sin},
    "cos" => {:math, :cos},
    "tan" => {:math, :tan},
    "ln" => {:math, :log},
    "log" => {:math, :log10},
    "exp" => {:math, :exp},
    "floor" => {:math, :floor},
    "ceil" => {:math, :ceil},
    "round" => {:erlang, :round}
  }

  @doc "Evaluate a pure arithmetic expression string."
  def eval_expression(src) when is_binary(src) do
    if String.trim(src) == "" do
      raise __MODULE__, {:"EXPR_EMPTY", "empty expression"}
    end

    tokens = tokenize(src)

    {value, pos} = parse_expr(tokens, 0)

    if pos != length(tokens) do
      raise __MODULE__, {:"EXPR_TRAILING", "trailing tokens"}
    end

    if not is_number(value) or :erlang.abs(value) == :infinity do
      raise __MODULE__, {:"EXPR_NON_FINITE", "non-finite result"}
    end

    value
  end

  defp tokenize(src) do
    regex = ~r/\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+)|([a-zA-Z_][a-zA-Z_0-9]*)|([-+*\/%^(),]))/

    tokens =
      Regex.scan(regex, src, capture: :all_but_first)
      |> Enum.flat_map(fn [num, id, op] ->
        cond do
          num != "" -> [{:num, String.to_float(normalize(num))}]
          id != "" -> [{:id, id}]
          op != "" -> [{:op, op}]
          true -> []
        end
      end)

    covered =
      Regex.scan(regex, src)
      |> Enum.map(fn [m | _] -> String.length(m) end)
      |> Enum.sum()

    if String.length(String.trim(src)) > covered do
      raise __MODULE__, {:"EXPR_BAD_CHAR", "unexpected character"}
    end

    tokens
  end

  defp normalize(num) do
    if String.contains?(num, "."), do: num, else: num <> ".0"
  end

  defp peek(tokens, pos), do: Enum.at(tokens, pos)

  defp eat(tokens, pos) do
    case Enum.at(tokens, pos) do
      nil -> raise __MODULE__, {:"EXPR_SYNTAX", "expected more tokens"}
      tok -> {tok, pos + 1}
    end
  end

  defp parse_expr(tokens, pos) do
    {v, pos} = parse_term(tokens, pos)
    parse_expr_tail(tokens, pos, v)
  end

  defp parse_expr_tail(tokens, pos, v) do
    case peek(tokens, pos) do
      {:op, "+"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_term(tokens, pos)
        parse_expr_tail(tokens, pos, v + r)

      {:op, "-"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_term(tokens, pos)
        parse_expr_tail(tokens, pos, v - r)

      _ ->
        {v, pos}
    end
  end

  defp parse_term(tokens, pos) do
    {v, pos} = parse_unary(tokens, pos)
    parse_term_tail(tokens, pos, v)
  end

  defp parse_term_tail(tokens, pos, v) do
    case peek(tokens, pos) do
      {:op, "*"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_unary(tokens, pos)
        parse_term_tail(tokens, pos, v * r)

      {:op, "/"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_unary(tokens, pos)
        parse_term_tail(tokens, pos, v / r)

      {:op, "%"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_unary(tokens, pos)
        parse_term_tail(tokens, pos, :math.fmod(v, r))

      _ ->
        {v, pos}
    end
  end

  defp parse_unary(tokens, pos) do
    case peek(tokens, pos) do
      {:op, "-"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {v, pos} = parse_unary(tokens, pos)
        {-v, pos}

      {:op, "+"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        parse_unary(tokens, pos)

      _ ->
        parse_power(tokens, pos)
    end
  end

  defp parse_power(tokens, pos) do
    {base, pos} = parse_atom(tokens, pos)

    case peek(tokens, pos) do
      {:op, "^"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {exp, pos} = parse_unary(tokens, pos)
        {:math.pow(base, exp), pos}

      _ ->
        {base, pos}
    end
  end

  defp parse_atom(tokens, pos) do
    {tok, pos} = eat(tokens, pos)

    case tok do
      {:num, v} ->
        {v, pos}

      {:id, id} ->
        name = String.downcase(id)

        case peek(tokens, pos) do
          {:op, "("} ->
            {{:op, _}, pos} = eat(tokens, pos)
            {args, pos} = parse_args(tokens, pos, [])
            apply_func(name, args, tokens, pos)

          _ ->
            case name do
              "pi" -> {:math.pi(), pos}
              "e" -> {:math.exp(1), pos}
              _ -> raise __MODULE__, {:"EXPR_UNKNOWN_ID", "unknown identifier #{name}"}
            end
        end

      {:op, "("} ->
        {v, pos} = parse_expr(tokens, pos)
        case eat(tokens, pos) do
          {{:op, ")"}, pos} -> {v, pos}
          _ -> raise __MODULE__, {:"EXPR_SYNTAX", "expected )"}
        end

      {:op, other} ->
        raise __MODULE__, {:"EXPR_SYNTAX", "unexpected token #{other}"}
    end
  end

  defp parse_args(tokens, pos, acc) do
    {v, pos} = parse_expr(tokens, pos)

    case peek(tokens, pos) do
      {:op, ","} ->
        {{:op, _}, pos} = eat(tokens, pos)
        parse_args(tokens, pos, acc ++ [v])

      {:op, ")"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {Enum.reverse(Enum.reverse(acc ++ [v])), pos}

      _ ->
        raise __MODULE__, {:"EXPR_SYNTAX", "expected ) or ,"}
    end
  end

  defp apply_func("min", args, _tokens, pos), do: {Enum.min(args), pos}
  defp apply_func("max", args, _tokens, pos), do: {Enum.max(args), pos}

  defp apply_func(name, args, _tokens, pos) do
    case Map.get(@funcs, name) do
      {mod, fun} -> {apply(mod, fun, [hd(args)]), pos}
      nil -> raise __MODULE__, {:"EXPR_UNKNOWN_FUNC", "unknown function #{name}"}
    end
  end

  defp numerically_equal(a, b) do
    abs(a - b) <= 1.0e-6 * max(1, max(abs(a), abs(b)))
  end

  defp parse_model_reply(text) when is_binary(text) do
    start = String.index(text, "{")
    e = String.rindex(text, "}")

    if is_nil(start) or is_nil(e) or e <= start do
      raise __MODULE__, {:"INVALID_JSON", "no JSON object in reply"}
    end

    body = String.slice(text, start..e)

    case Jason.decode(body) do
      {:ok, data} ->
        answer =
          case data["answer"] do
            n when is_number(n) -> n * 1.0
            s when is_binary(s) ->
              case Regex.run(~r/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, s) do
                [m] -> String.to_float(normalize(m))
                _ -> raise __MODULE__, {:"INVALID_JSON", "missing numeric answer"}
              end
            _ -> raise __MODULE__, {:"INVALID_JSON", "missing numeric answer"}
          end

        expression = get_in(data, ["verification", "expression"])

        if not is_binary(expression) do
          raise __MODULE__, {:"INVALID_JSON", "missing verification.expression"}
        end

        steps =
          case data["steps"] do
            list when is_list(list) -> Enum.map(list, &to_string/1)
            _ -> []
          end

        %{answer: answer, steps: steps, expression: expression}

      {:error, _} ->
        raise __MODULE__, {:"INVALID_JSON", "reply was not valid JSON"}
    end
  end

  defstruct [:api_key, :base_url, :model, :transport]

  @doc """
  BYOK client for an OpenAI-compatible endpoint. Instantiate once, solve many.

      {:ok, solver} = MathSolver.new(api_key: "sk-...", base_url: "https://api.deepseek.com/v1", model: "deepseek-chat")
      {:ok, result} = MathSolver.solve(solver, "2x + 3 = 11, solve for x")
  """
  @spec new(keyword()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def new(opts \ []) do
    api_key = Keyword.get(opts, :api_key, "")

    if api_key == "" do
      {:error, {:"NO_API_KEY", "api_key is required (BYOK)"}}
    else
      base = String.replace_trailing(to_string(Keyword.get(opts, :base_url, "https://api.openai.com/v1")), "/", "")

      if not String.starts_with?(base, ["http://", "https://"]) do
        {:error, {:"BAD_BASE_URL", "base_url must be an http(s) URL, e.g. https://api.deepseek.com/v1"}}
      else
        {:ok,
         %__MODULE__{
           api_key: api_key,
           base_url: base,
           model: Keyword.get(opts, :model, "gpt-4o-mini"),
           transport: Keyword.get(opts, :transport, &default_transport/3)
         }}
      end
    end
  end

  @doc "Like `new/1` but raises on invalid arguments."
  @spec new!(keyword()) :: %__MODULE__{}
  def new!(opts \ []) do
    case new(opts) do
      {:ok, solver} -> solver
      {:error, {code, msg}} -> raise __MODULE__, {code, msg}
    end
  end

  @doc "Solve a math problem. `verified` is true only when the expression re-evaluates to the answer."
  @spec solve(%__MODULE__{}, String.t()) :: {:ok, map()} | {:error, term()}
  def solve(%__MODULE__{} = solver, problem) do
    %{api_key: api_key, base_url: base_url, model: model, transport: transport} = solver

    if String.trim(problem) == "" do
      {:error, {:"NO_PROBLEM", "problem must be non-empty"}}
    else
      url = base_url <> "/chat/completions"

      messages = [
        %{role: "system", content: @system_prompt},
        %{role: "user", content: problem}
      ]

      call = fn msgs ->
        body = Jason.encode!(%{model: model, messages: msgs, temperature: 0})

        case transport.(url, body, api_key) do
          {:ok, reply} -> reply
          {:error, {code, msg}} -> raise __MODULE__, {code, msg}
          {:error, reason} -> raise __MODULE__, {:"HTTP_ERROR", to_string(reason)}
        end
      end

      try do
        parsed = parse_model_reply(call.(messages))
        evaluate = fn p ->
          try do
            ev = eval_expression(p.expression)
            {ev, numerically_equal(ev, p.answer)}
          rescue
            _ -> {nil, false}
          end
        end

        {evaluated, verified} = evaluate.(parsed)

        {parsed, verified, evaluated, retries} =
          if verified do
            {parsed, true, evaluated, 0}
          else
            messages =
              messages ++
                [
                  %{role: "user",
                    content:
                      "Your verification expression evaluated to #{evaluated || "an error"}, " <>
                        "which does not match your answer #{parsed.answer}. " <>
                        "Re-derive carefully and reply again with the same strict JSON shape."}
                ]

            try do
              second = parse_model_reply(call.(messages))

              case evaluate.(second) do
                {ev2, true} -> {second, true, ev2, 1}
                {ev2, false} -> {parsed, false, ev2 || evaluated, 1}
              end
            rescue
              _ -> {parsed, false, evaluated, 1}
            end
          end

        {:ok,
         %{
           answer: parsed.answer,
           steps: parsed.steps,
           expression: parsed.expression,
           evaluated: evaluated,
           verified: verified,
           retries: retries
         }}
      rescue
        e in __MODULE__ -> {:error, {e.code, e.message}}
      end
    end
  end

  def default_transport(url, body, api_key) do
    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> api_key}
    ]

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _, resp_body}} when status in 200..299 ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} when is_binary(content) ->
            {:ok, content}

          _ ->
            {:error, {:"HTTP_ERROR", "missing message content"}}
        end

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:"HTTP_ERROR", "API responded #{status}"}}

      {:error, reason} ->
        {:error, {:"HTTP_ERROR", inspect(reason)}}
    end
  end
end
