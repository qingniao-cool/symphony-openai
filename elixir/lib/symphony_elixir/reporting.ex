defmodule SymphonyElixir.Reporting do
  @moduledoc """
  Timezone-aware scheduler for Symphony's daily structured report.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, DailyReport}

  @retry_delay_ms 60_000

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    reporting = Keyword.get_lazy(opts, :reporting, &Config.reporting_settings/0)

    if reporting.enabled do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, Keyword.put(opts, :reporting, reporting), name: name)
    else
      :ignore
    end
  end

  @impl true
  def init(opts) do
    state = %{
      reporting: Keyword.fetch!(opts, :reporting),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      generator: Keyword.get(opts, :generator, &DailyReport.generate/1),
      send_after: Keyword.get(opts, :send_after, &Process.send_after/3)
    }

    {:ok, schedule_initial(state)}
  end

  @impl true
  def handle_info(:generate_report, state) do
    case state.generator.(state.reporting) do
      {:ok, result, path} ->
        Logger.info("Daily report #{result}: path=#{path}")
        {:noreply, schedule_next_day(state)}

      {:error, reason} ->
        Logger.error("Daily report generation failed: reason=#{inspect(reason)}; retrying")
        {:noreply, schedule(state, @retry_delay_ms)}
    end
  end

  @doc false
  @spec milliseconds_until_next(map(), DateTime.t()) :: non_neg_integer()
  def milliseconds_until_next(reporting, now) do
    local_now = DateTime.shift_zone!(now, reporting.timezone)
    scheduled_time = parse_time!(reporting.daily_at)
    date = if Time.compare(DateTime.to_time(local_now), scheduled_time) == :lt, do: DateTime.to_date(local_now), else: Date.add(DateTime.to_date(local_now), 1)
    scheduled = scheduled_datetime(date, scheduled_time, reporting.timezone)
    max(DateTime.diff(scheduled, now, :millisecond), 0)
  end

  defp schedule_initial(state) do
    local_now = DateTime.shift_zone!(state.now.(), state.reporting.timezone)
    scheduled_time = parse_time!(state.reporting.daily_at)

    if Time.compare(DateTime.to_time(local_now), scheduled_time) in [:eq, :gt] do
      send(self(), :generate_report)
      state
    else
      schedule(state, milliseconds_until_next(state.reporting, state.now.()))
    end
  end

  defp schedule_next_day(state), do: schedule(state, milliseconds_until_next(state.reporting, state.now.()))

  defp schedule(state, delay_ms) do
    state.send_after.(self(), :generate_report, delay_ms)
    state
  end

  defp parse_time!(daily_at) do
    {:ok, time} = Time.from_iso8601(daily_at <> ":00")
    time
  end

  defp scheduled_datetime(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _before, after_gap} -> after_gap
    end
  end
end
