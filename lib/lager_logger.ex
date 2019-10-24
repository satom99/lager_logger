defmodule LagerLogger do
  @moduledoc ~S"""
  A lager backend that forwards all log messages to Elixir's Logger.

  To forward all lager messages to Logger and otherwise disable lager
  include the following in a config.exs file:

      use Mix.Config

      # Stop lager redirecting :error_logger messages
      config :lager, :error_logger_redirect, false

      # Stop lager removing Logger's :error_logger handler
      config :lager, :error_logger_whitelist, [Logger.ErrorHandler]

      # Stop lager writing a crash log
      config :lager, :crash_log, false

      # Use LagerLogger as lager's only handler.
      config :lager, :handlers, [{LagerLogger, [level: :debug]}]
  """

  use Bitwise

  @behaviour :gen_event

  @doc """
  Flushes lager and Logger

  Guarantees that all messages sent to `:error_logger` and `:lager`, prior to
  this call, have been handled by Logger.
  """
  @spec flush() :: :ok
  def flush() do
    _ = GenEvent.which_handlers(:error_logger)
    _ = GenEvent.which_handlers(:lager_event)
    _ = GenEvent.which_handlers(Logger)
    :ok
  end

  @doc false
  def init(opts) do
    config = Keyword.get(opts, :level, :debug)
    case config_to_mask(config) do
      {:ok, _mask} = ok ->
        ok
      {:error, reason} ->
        {:error, {:fatal, reason}}
    end
  end

  # Elixir v1.9.0 has refactored logging, so now data fetched directly for log level
  if function_exported?(Logger.Config, :translation_data, 0) do
    @doc false
    def handle_event({:log, lager_msg}, mask) do
      level = severity_to_level(:lager_msg.severity(lager_msg))
      is_loggable? = :lager_util.is_loggable(lager_msg, mask, __MODULE__)

      case is_loggable? and Logger.Config.log_data(level) do
        false ->
          {:ok, mask}

        {:discard, _} ->
          {:ok, mask}

        {mode, config} ->
          do_log(level, lager_msg, mode, config)
          {:ok, mask}
      end
    end
  else
    @doc false
    def handle_event({:log, lager_msg}, mask) do
      %{mode: mode, level: min_level} = config = Logger.Config.__data__()

      level = severity_to_level(:lager_msg.severity(lager_msg))

      if :lager_util.is_loggable(lager_msg, mask, __MODULE__) and
           Logger.compare_levels(level, min_level) != :lt do
        do_log(level, lager_msg, mode, config)
        {:ok, mask}
      else
        {:ok, mask}
      end
    end
  end

  @doc false
  def handle_call(:get_loglevel, mask) do
    {:ok, mask, mask}
  end

  def handle_call({:set_loglevel, config}, mask) do
    case config_to_mask(config) do
      {:ok, mask} ->
        {:ok, :ok, mask}
      {:error, _reason} = error ->
        {:ok, error, mask}
    end
  end

  @doc false
  def handle_info(_msg, mask) do
    {:ok, mask}
  end

  @doc false
  def terminate(_reason, _mask), do: :ok

  @doc false
  def code_change(_old, mask, _extra), do: {:ok, mask}

  defp config_to_mask(config) do
    try do
      :lager_util.config_to_mask(config)
    catch
      _, _ ->
        {:error, {:bad_log_level, config}}
    else
      mask ->
        {:ok, mask}
    end
  end

  # Stolen from Logger.
  defp notify(:sync, msg),  do: GenEvent.sync_notify(Logger, msg)
  defp notify(:async, msg), do: GenEvent.notify(Logger, msg)

  @doc false
  # Lager's parse transform converts the pid into a charlist. Logger's metadata expects pids as
  # actual pids so we need to revert it.
  # If the pid metadata is not a valid pid we remove it completely.
  def normalize_pid(metadata) do
    case Keyword.fetch(metadata, :pid) do
      {:ok, pid} when is_pid(pid) -> metadata
      {:ok, pid} when is_list(pid) ->
        try do
          # Lager's parse transform uses `pid_to_list` so we revert it
          Keyword.put(metadata, :pid, :erlang.list_to_pid(pid))
        rescue
          ArgumentError -> Keyword.delete(metadata, :pid)
        end
      {:ok, _} -> Keyword.delete(metadata, :pid)
      :error -> metadata
    end
  end

  @doc false
  # Returns a timestamp that includes miliseconds. Stolen from Logger.Utils.
  def timestamp(now, utc_log?) do
    {_, _, micro} = now
    {date, {hours, minutes, seconds}} =
      case utc_log? do
        true  -> :calendar.now_to_universal_time(now)
        false -> :calendar.now_to_local_time(now)
      end
    {date, {hours, minutes, seconds, div(micro, 1000)}}
  end

  # Converts lager's severity to Logger's level
  defp severity_to_level(:debug),     do: :debug
  defp severity_to_level(:info),      do: :info
  defp severity_to_level(:notice),    do: :info
  defp severity_to_level(:warning),   do: :warn
  defp severity_to_level(:error),     do: :error
  defp severity_to_level(:critical),  do: :error
  defp severity_to_level(:alert),     do: :error
  defp severity_to_level(:emergency), do: :error

  defp do_log(level, lager_msg, mode, %{truncate: truncate, utc_log: utc_log?}) do
    metadata = :lager_msg.metadata(lager_msg) |> normalize_pid

    # lager_msg's message is already formatted chardata
    message = Logger.Utils.truncate(:lager_msg.message(lager_msg), truncate)

    # Lager always uses local time and converts it when formatting using :lager_util.maybe_utc
    timestamp = timestamp(:lager_msg.timestamp(lager_msg), utc_log?)

    group_leader = find_group_leader(metadata)

    _ = notify(mode, {level, group_leader, {Logger, message, timestamp, metadata}})
  end

  defp find_group_leader(metadata) do
    case Keyword.fetch(metadata, :pid) do
      {:ok, pid} when is_pid(pid) ->
        case Process.info(pid, :group_leader) do
          {:group_leader, gl} -> gl
          # if pid dead, pretend it's us as must be a pid
          nil -> Process.group_leader()
        end

      # if lager didn't give us a pid just pretend it's us
      _ ->
        Process.group_leader()
    end
  end
end
