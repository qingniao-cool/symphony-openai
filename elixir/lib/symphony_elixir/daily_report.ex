defmodule SymphonyElixir.DailyReport do
  @moduledoc """
  Builds and persists deterministic daily reports from tracker and orchestrator state.
  """

  alias SymphonyElixir.{Config, Orchestrator, Tracker}
  alias SymphonyElixir.Tracker.Issue

  @waiting_states ["Human Review", "In Review", "Merging", "Deploying", "Ready for Deploy", "Deployment"]
  @failure_states ["Blocked", "Failed"]

  @type latest_report :: %{date: Date.t(), path: Path.t(), content: String.t()}

  @spec generate(map(), keyword()) ::
          {:ok, :created | :existing, Path.t()} | {:error, term()}
  def generate(reporting \\ Config.reporting_settings(), opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    tracker_fetcher = Keyword.get(opts, :tracker_fetcher, &Tracker.fetch_issues_by_states/1)
    snapshot_fetcher = Keyword.get(opts, :snapshot_fetcher, &Orchestrator.snapshot/0)
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    local_now = DateTime.shift_zone!(now, reporting.timezone)
    date = DateTime.to_date(local_now)
    path = report_path(reporting.output_root, date)

    if File.exists?(path) do
      {:ok, :existing, path}
    else
      states = report_states(tracker_settings)

      with {:ok, issues} <- tracker_fetcher.(states),
           snapshot when is_map(snapshot) <- snapshot_fetcher.(),
           markdown <- render(date, local_now, issues, snapshot, tracker_settings, reporting.timezone),
           :ok <- File.mkdir_p(reporting.output_root) do
        write_once(path, markdown)
      else
        :timeout -> {:error, :orchestrator_timeout}
        :unavailable -> {:error, :orchestrator_unavailable}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec latest(Path.t()) :: {:ok, latest_report()} | {:error, :not_found | term()}
  def latest(output_root \\ Config.reporting_settings().output_root) do
    with {:ok, names} <- File.ls(output_root),
         [name | _] <- names |> Enum.filter(&report_filename?/1) |> Enum.sort(:desc),
         {:ok, date} <- name |> Path.rootname() |> Date.from_iso8601(),
         path = Path.join(output_root, name),
         {:ok, content} <- File.read(path) do
      {:ok, %{date: date, path: path, content: content}}
    else
      [] -> {:error, :not_found}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec render(Date.t(), DateTime.t(), [Issue.t()], map(), map(), String.t()) :: String.t()
  def render(date, generated_at, issues, snapshot, tracker_settings, timezone) do
    completed =
      issues
      |> Enum.filter(&(state_in?(&1.state, tracker_settings.terminal_states) and updated_on?(&1, date, timezone)))
      |> sort_issues()

    waiting = issues |> Enum.filter(&waiting?/1) |> sort_issues()

    active =
      issues
      |> Enum.filter(&(state_in?(&1.state, tracker_settings.active_states) and not waiting?(&1)))
      |> sort_issues()

    failed = issues |> Enum.filter(&state_in?(&1.state, @failure_states)) |> sort_issues()
    blocked = Map.get(snapshot, :blocked, []) |> Enum.sort_by(&entry_identifier/1)
    retrying = Map.get(snapshot, :retrying, []) |> Enum.sort_by(&entry_identifier/1)
    totals = Map.get(snapshot, :codex_totals, %{})

    """
    # Daily Report — #{Date.to_iso8601(date)}

    Generated at: #{DateTime.to_iso8601(generated_at)}
    Timezone: #{timezone}

    ## Completed today

    #{issue_lines(completed)}

    ## In progress

    #{issue_lines(active)}

    ## Waiting for human review, merge, or deployment

    #{issue_lines(waiting)}

    ## Blocked, failed, and retrying

    ### Blocked

    #{runtime_lines(blocked, :blocked)}

    ### Failed

    #{issue_lines(failed)}

    ### Retrying

    #{runtime_lines(retrying, :retrying)}

    ## Runtime metrics

    | Metric | Value |
    | --- | ---: |
    | Active agents | #{length(Map.get(snapshot, :running, []))} |
    | Runtime seconds | #{number_value(totals, :seconds_running)} |
    | Input tokens | #{integer_value(totals, :input_tokens)} |
    | Output tokens | #{integer_value(totals, :output_tokens)} |
    | Total tokens | #{integer_value(totals, :total_tokens)} |
    """
  end

  @doc false
  @spec report_path(Path.t(), Date.t()) :: Path.t()
  def report_path(root, date), do: Path.join(root, Date.to_iso8601(date) <> ".md")

  defp report_states(tracker_settings) do
    (tracker_settings.active_states ++ tracker_settings.terminal_states ++ @waiting_states ++ @failure_states)
    |> Enum.uniq()
  end

  defp write_once(path, markdown) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io_device} ->
        :ok = IO.binwrite(io_device, markdown)
        :ok = File.close(io_device)
        {:ok, :created, path}

      {:error, :eexist} ->
        {:ok, :existing, path}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp report_filename?(name), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}\.md$/, name)

  defp state_in?(state, states) when is_binary(state) and is_list(states) do
    normalized = normalize_state(state)
    Enum.any?(states, &(normalize_state(&1) == normalized))
  end

  defp state_in?(_state, _states), do: false

  defp waiting?(%Issue{state: state}) when is_binary(state) do
    normalized = normalize_state(state)

    state_in?(state, @waiting_states) or
      Enum.any?(["review", "merg", "deploy"], &String.contains?(normalized, &1))
  end

  defp waiting?(_issue), do: false

  defp normalize_state(state), do: state |> String.trim() |> String.downcase()

  defp updated_on?(%Issue{updated_at: %DateTime{} = updated_at}, date, timezone) do
    updated_at |> DateTime.shift_zone!(timezone) |> DateTime.to_date() == date
  end

  defp updated_on?(_issue, _date, _timezone), do: false

  defp sort_issues(issues), do: Enum.sort_by(issues, &{&1.identifier || "", &1.id || ""})

  defp issue_lines([]), do: "_None._"

  defp issue_lines(issues) do
    Enum.map_join(issues, "\n", fn issue ->
      identifier = markdown_text(issue.identifier || issue.id || "unknown")
      title = markdown_text(issue.title || "Untitled")
      state = markdown_text(issue.state || "Unknown")
      reference = if valid_http_url?(issue.url), do: "[#{identifier}](#{issue.url})", else: identifier
      "- #{reference} — #{title} (`#{state}`)"
    end)
  end

  defp runtime_lines([], _kind), do: "_None._"

  defp runtime_lines(entries, kind) do
    Enum.map_join(entries, "\n", fn entry ->
      identifier = markdown_text(entry_identifier(entry))
      error = markdown_text(Map.get(entry, :error) || "No error detail")
      attempt = if kind == :retrying, do: " (attempt #{Map.get(entry, :attempt, 0)})", else: ""
      reference = if valid_http_url?(Map.get(entry, :issue_url)), do: "[#{identifier}](#{entry.issue_url})", else: identifier
      "- #{reference}#{attempt} — #{error}"
    end)
  end

  defp entry_identifier(entry), do: Map.get(entry, :identifier) || Map.get(entry, :issue_id) || "unknown"

  defp integer_value(map, key) do
    case Map.get(map, key, 0) do
      value when is_integer(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp number_value(map, key) do
    case Map.get(map, key, 0) do
      value when is_number(value) and value >= 0 -> value
      _other -> 0
    end
  end

  defp markdown_text(value) do
    value
    |> to_string()
    |> String.replace(["\\", "`", "*", "_", "[", "]", "<", ">"], fn match -> "\\" <> match end)
    |> String.replace(["\r", "\n"], " ")
  end

  defp valid_http_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> true
      _other -> false
    end
  end

  defp valid_http_url?(_url), do: false
end
