defmodule Realtime.SynHandler do
  @moduledoc """
  Custom defined Syn's callbacks
  """
  require Logger
  alias Extensions.PostgresCdcRls
  alias RealtimeWeb.Endpoint
  alias Realtime.Tenants.Connect

  @behaviour :syn_event_handler

  @impl true
  def on_registry_process_updated(Connect, tenant_id, _pid, %{conn: conn}, :normal) when is_pid(conn) do
    # Update that a database connection is ready
    Endpoint.local_broadcast(Connect.syn_topic(tenant_id), "ready", %{conn: conn})
  end

  def on_registry_process_updated(PostgresCdcRls, tenant_id, _pid, meta, _reason) do
    # Update that the CdCRls connection is ready
    Endpoint.local_broadcast(PostgresCdcRls.syn_topic(tenant_id), "ready", meta)
  end

  def on_registry_process_updated(_scope, _name, _pid, _meta, _reason), do: :ok

  @doc """
  When processes registered with :syn are unregistered, either manually or by stopping, this
  callback is invoked.

  Other processes can subscribe to these events via PubSub to respond to them.

  We want to log conflict resolutions to know when more than one process on the cluster
  was started, and subsequently stopped because :syn handled the conflict.
  """
  @impl true
  def on_process_unregistered(mod, name, _pid, _meta, reason) do
    case reason do
      :syn_conflict_resolution ->
        Logger.warning("#{mod} terminated: #{inspect(name)} #{node()}")

      _ ->
        topic = topic(mod)
        Endpoint.local_broadcast(topic <> ":" <> name, topic <> "_down", nil)
    end

    :ok
  end

  @impl true
  def resolve_registry_conflict(mod, name, {pid1, %{region: region}, time1}, {pid2, _, time2}) do
    platform_region = Realtime.Nodes.platform_region_translator(region)

    platform_region_nodes =
      RegionNodes |> :syn.members(platform_region) |> Enum.map(fn {_, [node: node]} -> node end)

    {keep, stop} =
      [pid1, pid2]
      |> Enum.filter(fn pid ->
        Enum.member?(platform_region_nodes, node(pid))
      end)
      |> then(fn
        [pid] ->
          {pid, if(pid != pid1, do: pid1, else: pid2)}

        _ ->
          if time1 < time2 do
            {pid1, pid2}
          else
            {pid2, pid1}
          end
      end)

    if node() == node(stop) do
      spawn(fn -> resolve_conflict(mod, stop, name) end)
    else
      Logger.warning("Resolving #{name} conflict, remote pid: #{inspect(stop)}")
    end

    keep
  end

  def resolve_registry_conflict(mod, name, {pid1, _, time1}, {pid2, _, time2}) do
    resolve_registry_conflict(mod, name, {pid1, %{region: nil}, time1}, {pid2, %{region: nil}, time2})
  end

  defp resolve_conflict(mod, stop, name) do
    resp =
      if Process.alive?(stop) do
        try do
          DynamicSupervisor.stop(stop, :shutdown, 30_000)
        catch
          error, reason -> {:error, {error, reason}}
        end
      else
        :not_alive
      end

    topic = topic(mod)
    Endpoint.broadcast(topic <> ":" <> name, topic <> "_down", nil)

    Logger.warning("Resolving #{name} conflict, stop local pid: #{inspect(stop)}, response: #{inspect(resp)}")
  end

  defp topic(mod) do
    mod
    |> Macro.underscore()
    |> String.split("/")
    |> Enum.take(-1)
    |> hd()
  end
end
