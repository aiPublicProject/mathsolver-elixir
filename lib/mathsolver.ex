defmodule Mathsolver.Error do
  @moduledoc "Solver error with a machine-readable `code`."
  defexception [:code, :message]

  def exception({code, message}) when is_atom(code) do
    %__MODULE__{code: code, message: message}
  end
end

defmodule Mathsolver do
  @moduledoc """
  BYOK AI math solver with execution-based verification (v0.2).

  Correctness model (PAL-style): the model never states the answer.
  It returns a small JavaScript-like PROGRAM; this library executes the
  program deterministically and the execution output IS the answer.
  For equations, a CHECK expression ({x} placeholder) must evaluate to 0
  when the computed answer is substituted back into the original equation.
  """

  @system_prompt """
  You are a precise math solver.
  Reply with STRICT JSON only, no markdown fences, in this exact shape:
  {"program": "<string>", "steps": [<string>, ...], "check": "<string>"}
  Rules:
  - "program" is a small JavaScript-like program that computes the final answer.
    One statement per line (or ; separated). Allowed statements:
        let NAME = EXPRESSION
        result = EXPRESSION
    EXPRESSIONs may use numbers, + - * / % ^ ( ), the functions
    abs sqrt sin cos tan ln log exp floor ceil round min max
    (log is base 10, ln is natural), the constants pi and e, and any
    variable defined by an earlier let. The value assigned to "result"
    is the answer. Never state the answer as a number in text.
  - "steps" is an array of short plain-language explanation strings.
  - "check" is a verification expression containing the placeholder {x}.
    After solving, {x} is replaced by the computed answer and the whole
    expression must evaluate to 0.
    For equations, substitute the answer back into the original equation
    (e.g. 2x+3=11 -> "2*{x}+3-11").
    For arithmetic, recompute via a different path and subtract the answer
    (e.g. 15% of 80 -> "80*15/100-{x}"). Provide "check" whenever possible.
  """

  defp correction_prompt(reason) do
    "Your submission failed verification: " <> reason <>
      ". Re-derive the problem carefully and reply again with the same strict JSON shape."
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

  @doc "Evaluate a pure arithmetic expression string. `env` maps variable names (case-sensitive, shadow pi/e) to values."
  @spec eval_expression(String.t(), %{optional(String.t()) => float()}) :: float()
  def eval_expression(src, env \\ %{}) when is_binary(src) do
    if String.trim(src) == "" do
      raise Mathsolver.Error, {:"EXPR_EMPTY", "empty expression"}
    end

    tokens = tokenize(src)

    {value, pos} = parse_expr(tokens, 0, env)

    if pos != length(tokens) do
      raise Mathsolver.Error, {:"EXPR_TRAILING", "trailing tokens"}
    end

    if not is_number(value) or :erlang.abs(value) == :infinity do
      raise Mathsolver.Error, {:"EXPR_NON_FINITE", "non-finite result"}
    end

    value
  end

  @doc """
  Execute a model-generated program. Statements (one per line or ; separated):
  let NAME = EXPR | NAME = EXPR | bare EXPR. The answer is the value of
  `result`, else the last bare expression. The model never states the answer
  as a number — execution output IS the answer.
  """
  @spec run_program(String.t()) :: float()
  def run_program(src) when is_binary(src) do
    if String.trim(src) == "" do
      raise Mathsolver.Error, {:"PROGRAM_EMPTY", "empty program"}
    end

    lines =
      src
      |> String.split(~r/[\n;]+/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if lines == [] do
      raise Mathsolver.Error, {:"PROGRAM_EMPTY", "empty program"}
    end

    {env, result_defined, last} =
      Enum.reduce(lines, {%{}, false, :none}, fn line, {env, rd, last} ->
        cond do
          captures = Regex.run(~r/^let\s+([a-zA-Z_]\w*)\s*=\s*(.+)$/, line) ->
            [_, name, rhs] = captures
            value = eval_expression(rhs, env)
            {Map.put(env, name, value), rd or name == "result", last}

          captures = Regex.run(~r/^([a-zA-Z_]\w*)\s*=\s*(.+)$/, line) ->
            [_, name, rhs] = captures
            value = eval_expression(rhs, env)
            {Map.put(env, name, value), rd or name == "result", last}

          true ->
            {env, rd, eval_expression(line, env)}
        end
      end)

    cond do
      result_defined -> Map.fetch!(env, "result")
      last != :none -> last
      true -> raise Mathsolver.Error, {:"PROGRAM_NO_RESULT", "program produced no result"}
    end
  end

  @doc """
  Substitute the computed answer into a check expression ({x} placeholder) and
  evaluate it. Returns `%{value:, passed:}`; passed when ~0 (scaled tolerance).
  """
  @spec run_check(String.t(), float()) :: %{value: float(), passed: boolean()}
  def run_check(check_src, answer) when is_binary(check_src) and is_number(answer) do
    substituted =
      Regex.replace(~r/\{\s*x\s*\}/i, check_src, "(" <> Float.to_string(answer / 1) <> ")")

    value = eval_expression(substituted)
    %{value: value, passed: abs(value) <= 1.0e-6 * max(1, abs(answer))}
  end

  defp tokenize(src) do
    regex = ~r/\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|\.\d+)|([a-zA-Z_][a-zA-Z_0-9]*)|([-+*\/%^(),]))/

    tokens =
      Regex.scan(regex, src, capture: :all_but_first)
      |> Enum.reject(&(&1 == []))
      |> Enum.flat_map(fn groups ->
        padded = Enum.take(groups ++ List.duplicate(nil, 3), 3)
        [num, id, op] = Enum.map(padded, fn g -> (is_nil(g) and "") || g end)

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
      raise Mathsolver.Error, {:"EXPR_BAD_CHAR", "unexpected character"}
    end

    tokens
  end

  defp normalize(num) do
    if String.contains?(num, "."), do: num, else: num <> ".0"
  end

  defp peek(tokens, pos), do: Enum.at(tokens, pos)

  defp eat(tokens, pos) do
    case Enum.at(tokens, pos) do
      nil -> raise Mathsolver.Error, {:"EXPR_SYNTAX", "expected more tokens"}
      tok -> {tok, pos + 1}
    end
  end

  defp parse_expr(tokens, pos, env) do
    {v, pos} = parse_term(tokens, pos, env)
    parse_expr_tail(tokens, pos, v, env)
  end

  defp parse_expr_tail(tokens, pos, v, env) do
    case peek(tokens, pos) do
      {:op, "+"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_term(tokens, pos, env)
        parse_expr_tail(tokens, pos, v + r, env)

      {:op, "-"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_term(tokens, pos, env)
        parse_expr_tail(tokens, pos, v - r, env)

      _ ->
        {v, pos}
    end
  end

  defp parse_term(tokens, pos, env) do
    {v, pos} = parse_unary(tokens, pos, env)
    parse_term_tail(tokens, pos, v, env)
  end

  defp parse_term_tail(tokens, pos, v, env) do
    case peek(tokens, pos) do
      {:op, "*"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_unary(tokens, pos, env)
        parse_term_tail(tokens, pos, v * r, env)

      {:op, "/"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_unary(tokens, pos, env)
        parse_term_tail(tokens, pos, v / r, env)

      {:op, "%"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {r, pos} = parse_unary(tokens, pos, env)
        parse_term_tail(tokens, pos, :math.fmod(v, r), env)

      _ ->
        {v, pos}
    end
  end

  defp parse_unary(tokens, pos, env) do
    case peek(tokens, pos) do
      {:op, "-"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {v, pos} = parse_unary(tokens, pos, env)
        {-v, pos}

      {:op, "+"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        parse_unary(tokens, pos, env)

      _ ->
        parse_power(tokens, pos, env)
    end
  end

  defp parse_power(tokens, pos, env) do
    {base, pos} = parse_atom(tokens, pos, env)

    case peek(tokens, pos) do
      {:op, "^"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {exp, pos} = parse_unary(tokens, pos, env)
        {:math.pow(base, exp), pos}

      _ ->
        {base, pos}
    end
  end

  defp parse_atom(tokens, pos, env) do
    {tok, pos} = eat(tokens, pos)

    case tok do
      {:num, v} ->
        {v, pos}

      {:id, id} ->
        case Map.fetch(env, id) do
          {:ok, bound} ->
            {bound, pos}

          :error ->
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
                  _ -> raise Mathsolver.Error, {:"EXPR_UNKNOWN_ID", "unknown identifier #{name}"}
                end
            end
        end

      {:op, "("} ->
        {v, pos} = parse_expr(tokens, pos, env)

        case eat(tokens, pos) do
          {{:op, ")"}, pos} -> {v, pos}
          _ -> raise Mathsolver.Error, {:"EXPR_SYNTAX", "expected )"}
        end

      {:op, other} ->
        raise Mathsolver.Error, {:"EXPR_SYNTAX", "unexpected token #{other}"}
    end
  end

  defp parse_args(tokens, pos, acc) do
    {v, pos} = parse_expr(tokens, pos, %{})

    case peek(tokens, pos) do
      {:op, ","} ->
        {{:op, _}, pos} = eat(tokens, pos)
        parse_args(tokens, pos, acc ++ [v])

      {:op, ")"} ->
        {{:op, _}, pos} = eat(tokens, pos)
        {Enum.reverse(Enum.reverse(acc ++ [v])), pos}

      _ ->
        raise Mathsolver.Error, {:"EXPR_SYNTAX", "expected ) or ,"}
    end
  end

  defp apply_func("min", args, _tokens, pos), do: {Enum.min(args), pos}
  defp apply_func("max", args, _tokens, pos), do: {Enum.max(args), pos}

  defp apply_func(name, args, _tokens, pos) do
    case Map.get(@funcs, name) do
      {mod, fun} -> {apply(mod, fun, [hd(args)]), pos}
      nil -> raise Mathsolver.Error, {:"EXPR_UNKNOWN_FUNC", "unknown function #{name}"}
    end
  end

  defp parse_model_reply(text) when is_binary(text) do
    start = case :binary.match(text, "{") do
      {i, _} -> i
      :nomatch -> nil
    end

    e = text |> :binary.matches("}") |> List.last() |> case do
      nil -> nil
      {i, _} -> i
    end

    if is_nil(start) or is_nil(e) or e <= start do
      raise Mathsolver.Error, {:"INVALID_JSON", "no JSON object in reply"}
    end

    body = binary_part(text, start, e - start + 1)

    case Jason.decode(body) do
      {:ok, data} ->
        program = data["program"]

        if not is_binary(program) or String.trim(program) == "" do
          raise Mathsolver.Error, {:"INVALID_JSON", "missing program"}
        end

        steps =
          case data["steps"] do
            list when is_list(list) -> Enum.map(list, &to_string/1)
            _ -> []
          end

        check =
          case data["check"] do
            s when is_binary(s) ->
              if String.trim(s) == "" do
                nil
              else
                s
              end

            _ ->
              nil
          end

        %{program: program, steps: steps, check: check}

      {:error, _} ->
        raise Mathsolver.Error, {:"INVALID_JSON", "reply was not valid JSON"}
    end
  end

  defstruct [:api_key, :base_url, :model, :transport, :http_post]

  @doc """
  BYOK client for an OpenAI-compatible endpoint. Instantiate once, solve many.

      {:ok, solver} = Mathsolver.new(api_key: "sk-...", base_url: "https://api.deepseek.com/v1", model: "deepseek-chat")
      {:ok, result} = Mathsolver.solve(solver, "2x + 3 = 11, solve for x")

  Options:

    * `:transport` — test injection `(url, body, api_key) -> {:ok, content} | {:error, _}`
    * `:http_post` — test seam below the default transport:
      `(url, headers, body) -> {:ok, {status, raw_body}} | {:error, _}` (no sockets)
  """
  @spec new(keyword()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def new(opts \\ []) do
    api_key = Keyword.get(opts, :api_key, "")

    if api_key == "" do
      {:error, {:"NO_API_KEY", "api_key is required (BYOK)"}}
    else
      base = String.replace_trailing(to_string(Keyword.get(opts, :base_url, "https://api.openai.com/v1")), "/", "")

      if not String.starts_with?(base, ["http://", "https://"]) do
        {:error, {:"BAD_BASE_URL", "base_url must be an http(s) URL, e.g. https://api.deepseek.com/v1"}}
      else
        http_post = Keyword.get(opts, :http_post, &__MODULE__.real_http_post/3)

        transport =
          Keyword.get(opts, :transport) || fn url, body, api_key ->
            with {:ok, reply} <-
                   http_post.(url, [{"content-type", "application/json"}, {"authorization", "Bearer " <> api_key}], body),
                 {:ok, content} <- content_from_response(reply) do
              {:ok, content}
            end
          end

        {:ok,
         %__MODULE__{
           api_key: api_key,
           base_url: base,
           model: Keyword.get(opts, :model, "gpt-4o-mini"),
           transport: transport,
           http_post: http_post
         }}
      end
    end
  end

  @doc "Like `new/1` but raises on invalid arguments."
  @spec new!(keyword()) :: %__MODULE__{}
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, solver} -> solver
      {:error, {code, msg}} -> raise Mathsolver.Error, {code, msg}
    end
  end

  @doc """
  Solve a math problem. `answer` is the output of executing the model's
  program; `verified` is true only when the check expression ({x} substituted
  with the answer) evaluated to ~0.
  """
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
          {:error, {code, msg}} -> raise Mathsolver.Error, {code, msg}
          {:error, reason} -> raise Mathsolver.Error, {:"HTTP_ERROR", to_string(reason)}
        end
      end

      try do
        parsed =
          try do
            parse_model_reply(call.(messages))
          rescue
            e in Mathsolver.Error ->
              if e.code != :"INVALID_JSON" do
                reraise(e, __STACKTRACE__)
              end

              messages =
                messages ++
                  [
                    %{role: "assistant", content: "invalid JSON"},
                    %{role: "user", content: "Your reply was not valid JSON. Reply again with the exact strict JSON shape."}
                  ]

              parse_model_reply(call.(messages))
          end

        attempt = fn p ->
          try do
            answer = run_program(p.program)

            {check_value, verified} =
              if p.check do
                result = run_check(p.check, answer)
                {result.value, result.passed}
              else
                {nil, false}
              end

            {:ok, %{answer: answer, check_value: check_value, verified: verified}}
          rescue
            e in Mathsolver.Error -> {:err, e}
          end
        end

        outcome = attempt.(parsed)

        {parsed, outcome, retries} =
          case outcome do
            {:ok, %{verified: true}} ->
              {parsed, outcome, 0}

            _ ->
              reason =
                case outcome do
                  {:err, e} -> "program failed to execute (#{e.code}: #{e.message})"
                  {:ok, %{check_value: cv}} -> "check evaluated to #{inspect(cv)} instead of 0"
                end

              messages =
                messages ++
                  [
                    %{role: "assistant", content: Jason.encode!(%{program: parsed.program, steps: parsed.steps, check: parsed.check})},
                    %{role: "user", content: correction_prompt(reason)}
                  ]

              second_parsed = parse_model_reply(call.(messages))

              case attempt.(second_parsed) do
                {:err, e} ->
                  raise(e)

                second ->
                  {second_parsed, second, 1}
              end
          end

        {:ok,
         %{
           answer: elem(outcome, 1).answer,
           steps: parsed.steps,
           program: parsed.program,
           check: parsed.check,
           check_value: elem(outcome, 1).check_value,
           verified: elem(outcome, 1).verified,
           retries: retries
         }}
      rescue
        e in Mathsolver.Error -> {:error, {e.code, e.message}}
      end
    end
  end

  @doc """
  Real HTTP POST via `:httpc`. Returns `{:ok, {status, raw_body}}` or `{:error, {code, msg}}`.
  Swap it out via `new(http_post: ...)` to test the default transport without sockets.
  """
  def real_http_post(url, headers, body) do
    # :httpc validates header field names as charlists — binaries raise
    # {:headers_error, :invalid_field}, so convert before the request.
    headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    case :httpc.request(:post, {String.to_charlist(url), headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, status, _}, _, resp_body}} -> {:ok, {status, to_string(resp_body)}}
      {:error, reason} -> {:error, {:"HTTP_ERROR", inspect(reason)}}
    end
  end

  defp content_from_response({status, body}) do
    if status >= 300 do
      {:error, {:"HTTP_ERROR", "API responded #{status}"}}
    else
      case Jason.decode(body) do
        {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} when is_binary(content) ->
          {:ok, content}

        _ ->
          {:error, {:"HTTP_ERROR", "missing message content"}}
      end
    end
  end

  def default_transport(url, body, api_key) do
    with {:ok, reply} <-
           real_http_post(url, [{"content-type", "application/json"}, {"authorization", "Bearer " <> api_key}], body),
         {:ok, content} <- content_from_response(reply) do
      {:ok, content}
    end
  end
end
