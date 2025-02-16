defmodule Appsignal.Probes do
  @moduledoc false
  use GenServer
  require Logger

  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def register(name, probe, state \\ nil) do
    if genserver_running?() do
      if is_function(probe) do
        GenServer.cast(__MODULE__, {:register, {name, probe, state}})
        :ok
      else
        Logger.debug(fn ->
          "Trying to register probe #{name}. Ignoring probe since it's not a function."
        end)

        {:error, "Probe is not a function"}
      end
    else
      {:error, "Probe genserver is not running"}
    end
  end

  def unregister(name) do
    GenServer.cast(__MODULE__, {:unregister, name})
    :ok
  end

  def init([]) do
    schedule_probes()
    {:ok, {%{}, %{}}}
  end

  def handle_cast({:register, {name, probe, state}}, {probes, states}) do
    if Map.has_key?(probes, name) do
      Logger.debug(fn -> "A probe with name '#{name}' already exists. Overriding that one." end)
    end

    {:noreply,
     {
       Map.put(probes, name, probe),
       Map.put(states, name, state)
     }}
  end

  def handle_cast({:unregister, name}, {probes, states}) do
    {:noreply,
     {
       Map.delete(probes, name),
       Map.delete(states, name)
     }}
  end

  def handle_info(:run_probes, {probes, states}) do
    states =
      if Appsignal.Config.minutely_probes_enabled?() do
        stream =
          Task.async_stream(
            probes,
            fn {name, probe} ->
              state = Map.get(states, name)

              try do
                {name, call_probe(probe, state)}
              rescue
                e ->
                  Logger.error("Error while calling probe #{name}: #{inspect(e)}")
                  {name, state}
              end
            end,
            ordered: false,
            timeout: 30000,
            on_timeout: :kill_task
          )

        Enum.reduce(stream, states, fn result, states ->
          case result do
            {:ok, {name, state}} -> Map.put(states, name, state)
            {:exit, :timeout} -> states
          end
        end)
      else
        states
      end

    schedule_probes()
    {:noreply, {probes, states}}
  end

  defp call_probe(probe, _state) when is_function(probe, 0) do
    probe.()
    nil
  end

  defp call_probe(probe, state) when is_function(probe, 1) do
    probe.(state)
  end

  def child_spec(_) do
    %{
      id: Appsignal.Probes,
      start: {Appsignal.Probes, :start_link, []}
    }
  end

  defp genserver_running? do
    pid = Process.whereis(__MODULE__)
    !is_nil(pid) && Process.alive?(pid)
  end

  if Mix.env() in [:test, :test_no_nif] do
    defp schedule_probes do
      Process.send_after(self(), :run_probes, 10)
    end
  else
    defp schedule_probes do
      Process.send_after(self(), :run_probes, (60 - DateTime.utc_now().second) * 1000)
    end
  end
end
