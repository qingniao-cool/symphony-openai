defmodule SymphonyElixir.DailyReportTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config.Schema, DailyReport, Reporting}
  alias SymphonyElixir.Tracker.Issue

  test "reporting config defaults to disabled and validates schedule fields" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.reporting.enabled == false
    assert settings.reporting.daily_at == "18:00"
    assert settings.reporting.timezone == "Etc/UTC"
    assert settings.reporting.output_root == "./reports"

    assert {:ok, settings} =
             Schema.parse(%{
               reporting: %{
                 enabled: true,
                 daily_at: "18:30",
                 timezone: "Asia/Shanghai",
                 output_root: "./daily"
               }
             })

    assert settings.reporting.enabled

    assert {:error, {:invalid_workflow_config, error}} =
             Schema.parse(%{reporting: %{daily_at: "25:00", timezone: "Mars/Olympus", output_root: ""}})

    assert error =~ "reporting.daily_at"
    assert error =~ "reporting.timezone"
    assert error =~ "reporting.output_root"
  end

  test "generates categorized Markdown from structured data and never overwrites the same date" do
    root = tmp_dir("content")
    on_exit(fn -> File.rm_rf(root) end)
    now = ~U[2026-10-19 10:30:00Z]
    reporting = reporting(root)
    parent = self()

    issues = [
      issue("KHI-1", "Done today", "Done", ~U[2026-10-19 09:00:00Z]),
      issue("KHI-2", "Active work", "In Progress", ~U[2026-10-18 09:00:00Z]),
      issue("KHI-3", "Needs review", "Human Review", ~U[2026-10-19 09:00:00Z]),
      issue("KHI-4", "Broken", "Failed", ~U[2026-10-19 09:00:00Z]),
      issue("KHI-5", "Old completion", "Done", ~U[2026-10-17 09:00:00Z])
    ]

    snapshot = %{
      running: [%{identifier: "KHI-2"}],
      blocked: [%{issue_id: "blocked", identifier: "KHI-6", error: "approval required"}],
      retrying: [%{issue_id: "retry", identifier: "KHI-7", attempt: 3, error: "API timeout"}],
      codex_totals: %{input_tokens: 100, output_tokens: 25, total_tokens: 125, seconds_running: 90.5}
    }

    fetcher = fn states ->
      send(parent, {:fetched_states, states})
      {:ok, issues}
    end

    opts = [
      now: now,
      tracker_fetcher: fetcher,
      snapshot_fetcher: fn -> snapshot end,
      tracker_settings: tracker_settings()
    ]

    assert {:ok, :created, path} = DailyReport.generate(reporting, opts)
    assert path == Path.join(root, "2026-10-19.md")
    assert_receive {:fetched_states, states}
    assert "Human Review" in states
    assert "Failed" in states

    content = File.read!(path)
    assert content =~ "# Daily Report — 2026-10-19"
    assert content =~ "[KHI-1](https://example.test/KHI-1) — Done today (`Done`)"
    refute content =~ "Old completion"
    assert content =~ "KHI-2"
    assert content =~ "KHI-3"
    assert content =~ "KHI-4"
    assert content =~ "KHI-6 — approval required"
    assert content =~ "KHI-7 (attempt 3) — API timeout"
    assert content =~ "| Active agents | 1 |"
    assert content =~ "| Runtime seconds | 90.5 |"
    assert content =~ "| Total tokens | 125 |"

    File.write!(path, content <> "\nmarker")
    assert {:ok, :existing, ^path} = DailyReport.generate(reporting, opts)
    assert File.read!(path) =~ "marker"
    refute_receive {:fetched_states, _states}

    assert {:ok, %{date: ~D[2026-10-19], path: ^path, content: latest}} = DailyReport.latest(root)
    assert latest =~ "marker"
  end

  test "does not create a report when a structured source is unavailable" do
    root = tmp_dir("failure")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:error, :orchestrator_unavailable} =
             DailyReport.generate(reporting(root),
               now: ~U[2026-10-19 10:30:00Z],
               tracker_fetcher: fn _states -> {:ok, []} end,
               snapshot_fetcher: fn -> :unavailable end,
               tracker_settings: tracker_settings()
             )

    refute File.exists?(Path.join(root, "2026-10-19.md"))
  end

  test "disabled reporting starts no process" do
    assert :ignore = Reporting.start_link(reporting: %{reporting(tmp_dir("disabled")) | enabled: false})
  end

  test "restart after the configured time immediately recovers today's report" do
    parent = self()
    settings = reporting(tmp_dir("recovery"))
    name = unique_name("Recovery")

    start_supervised!(
      {Reporting,
       name: name,
       reporting: settings,
       now: fn -> ~U[2026-10-19 10:30:00Z] end,
       generator: fn received ->
         send(parent, {:generated, received})
         {:ok, :created, "/tmp/report.md"}
       end,
       send_after: fn _pid, message, delay ->
         send(parent, {:scheduled, message, delay})
         make_ref()
       end}
    )

    assert_receive {:generated, ^settings}
    assert_receive {:scheduled, :generate_report, delay}
    assert delay > 0
    assert delay <= 24 * 60 * 60 * 1_000
  end

  test "before the configured time schedules today without generating early" do
    parent = self()
    settings = reporting(tmp_dir("scheduled"))
    name = unique_name("Scheduled")

    start_supervised!(
      {Reporting,
       name: name,
       reporting: settings,
       now: fn -> ~U[2026-10-19 09:00:00Z] end,
       generator: fn _received ->
         send(parent, :generated_too_early)
         {:ok, :created, "/tmp/report.md"}
       end,
       send_after: fn _pid, message, delay ->
         send(parent, {:scheduled, message, delay})
         make_ref()
       end}
    )

    assert_receive {:scheduled, :generate_report, 3_600_000}
    refute_receive :generated_too_early
  end

  test "next run calculation honors timezone day boundaries" do
    settings = reporting(tmp_dir("timezone"))
    assert Reporting.milliseconds_until_next(settings, ~U[2026-10-19 09:00:00Z]) == 3_600_000
    assert Reporting.milliseconds_until_next(settings, ~U[2026-10-19 11:00:00Z]) == 23 * 60 * 60 * 1_000
  end

  defp reporting(root) do
    %{enabled: true, daily_at: "18:00", timezone: "Asia/Shanghai", output_root: root}
  end

  defp tracker_settings do
    %{active_states: ["Todo", "In Progress"], terminal_states: ["Done", "Canceled"]}
  end

  defp issue(identifier, title, state, updated_at) do
    %Issue{
      id: String.downcase(identifier),
      identifier: identifier,
      title: title,
      state: state,
      url: "https://example.test/#{identifier}",
      updated_at: updated_at
    }
  end

  defp tmp_dir(suffix) do
    Path.join(System.tmp_dir!(), "symphony-report-#{suffix}-#{System.unique_integer([:positive])}")
  end

  defp unique_name(suffix), do: Module.concat(__MODULE__, "#{suffix}#{System.unique_integer([:positive])}")
end
