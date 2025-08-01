defmodule Realtime.Tenants.ReplicationConnectionTest do
  # Async false due to tweaking application env
  use Realtime.DataCase, async: false
  use Mimic
  setup :set_mimic_global

  import ExUnit.CaptureLog

  alias Realtime.Api.Message
  alias Realtime.Database
  alias Realtime.Tenants
  alias Realtime.Tenants.ReplicationConnection
  alias RealtimeWeb.Endpoint

  setup do
    slot = Application.get_env(:realtime, :slot_name_suffix)
    on_exit(fn -> Application.put_env(:realtime, :slot_name_suffix, slot) end)
    Application.put_env(:realtime, :slot_name_suffix, "test")

    tenant = Containers.checkout_tenant(run_migrations: true)

    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    name = "supabase_realtime_messages_replication_slot_test"
    Postgrex.query(db_conn, "SELECT pg_drop_replication_slot($1)", [name])
    Process.exit(db_conn, :normal)

    %{tenant: tenant}
  end

  for adapter <- [:phoenix, :gen_rpc] do
    describe "replication with #{adapter}" do
      @describetag adapter: adapter

      setup %{tenant: tenant, adapter: broadcast_adapter} do
        {:ok, tenant} = Realtime.Api.update_tenant(tenant, %{broadcast_adapter: broadcast_adapter})
        %{tenant: tenant}
      end

      test "fails if tenant connection is invalid" do
        tenant =
          tenant_fixture(%{
            "extensions" => [
              %{
                "type" => "postgres_cdc_rls",
                "settings" => %{
                  "db_host" => "127.0.0.1",
                  "db_name" => "postgres",
                  "db_user" => "supabase_admin",
                  "db_password" => "postgres",
                  "db_port" => "9001",
                  "poll_interval" => 100,
                  "poll_max_changes" => 100,
                  "poll_max_record_bytes" => 1_048_576,
                  "region" => "us-east-1",
                  "ssl_enforced" => true
                }
              }
            ]
          })

        assert {:error, _} = ReplicationConnection.start(tenant, self())
      end

      test "starts a handler for the tenant and broadcasts", %{tenant: tenant} do
        start_link_supervised!(
          {ReplicationConnection, %ReplicationConnection{tenant_id: tenant.external_id, monitored_pid: self()}},
          restart: :transient
        )

        topic = random_string()
        tenant_topic = Tenants.tenant_topic(tenant.external_id, topic, false)
        subscribe(tenant_topic, topic)

        total_messages = 5
        # Works with one insert per transaction
        for _ <- 1..total_messages do
          value = random_string()

          row =
            message_fixture(tenant, %{
              "topic" => topic,
              "private" => true,
              "event" => "INSERT",
              "payload" => %{"value" => value}
            })

          assert_receive {:socket_push, :text, data}
          message = data |> IO.iodata_to_binary() |> Jason.decode!()

          payload = %{
            "event" => "INSERT",
            "payload" => %{
              "id" => row.id,
              "value" => value
            },
            "type" => "broadcast"
          }

          assert message == %{"event" => "broadcast", "payload" => payload, "ref" => nil, "topic" => topic}
        end

        Process.sleep(500)
        # Works with batch inserts
        messages =
          for _ <- 1..total_messages do
            Message.changeset(%Message{}, %{
              "topic" => topic,
              "private" => true,
              "event" => "INSERT",
              "extension" => "broadcast",
              "payload" => %{"value" => random_string()}
            })
          end

        {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
        {:ok, _} = Realtime.Repo.insert_all_entries(db_conn, messages, Message)

        messages_received =
          for _ <- 1..total_messages, into: [] do
            assert_receive {:socket_push, :text, data}
            data |> IO.iodata_to_binary() |> Jason.decode!()
          end

        for row <- messages do
          assert Enum.count(messages_received, fn message_received ->
                   value = row |> Map.from_struct() |> get_in([:changes, :payload, "value"])

                   match?(
                     %{
                       "event" => "broadcast",
                       "payload" => %{
                         "event" => "INSERT",
                         "payload" => %{
                           "id" => _,
                           "value" => ^value
                         }
                       },
                       "ref" => nil,
                       "topic" => ^topic
                     },
                     message_received
                   )
                 end) == 1
        end
      end

      test "monitored pid stopping brings down ReplicationConnection ", %{tenant: tenant} do
        monitored_pid =
          spawn(fn ->
            receive do
              :stop -> :ok
            end
          end)

        logs =
          capture_log(fn ->
            pid =
              start_supervised!(
                {ReplicationConnection,
                 %ReplicationConnection{tenant_id: tenant.external_id, monitored_pid: monitored_pid}},
                restart: :transient
              )

            send(monitored_pid, :stop)

            ref = Process.monitor(pid)
            assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 100
            refute Process.alive?(pid)
          end)

        assert logs =~ "Disconnecting broadcast changes handler in the step"
      end

      test "message without event logs error", %{tenant: tenant} do
        logs =
          capture_log(fn ->
            start_supervised!(
              {ReplicationConnection, %ReplicationConnection{tenant_id: tenant.external_id, monitored_pid: self()}},
              restart: :transient
            )

            topic = random_string()
            tenant_topic = Tenants.tenant_topic(tenant.external_id, topic, false)
            assert :ok = Endpoint.subscribe(tenant_topic)

            message_fixture(tenant, %{
              "topic" => "some_topic",
              "private" => true,
              "payload" => %{"value" => "something"}
            })

            refute_receive %Phoenix.Socket.Broadcast{}, 500
          end)

        assert logs =~ "UnableToBroadcastChanges"
      end

      test "payload without id", %{tenant: tenant} do
        start_link_supervised!(
          {ReplicationConnection, %ReplicationConnection{tenant_id: tenant.external_id, monitored_pid: self()}},
          restart: :transient
        )

        topic = random_string()
        tenant_topic = Tenants.tenant_topic(tenant.external_id, topic, false)
        subscribe(tenant_topic, topic)

        fixture =
          message_fixture(tenant, %{
            "topic" => topic,
            "private" => true,
            "event" => "INSERT",
            "payload" => %{"value" => "something"}
          })

        assert_receive {:socket_push, :text, data}, 500
        message = data |> IO.iodata_to_binary() |> Jason.decode!()

        assert %{
                 "event" => "broadcast",
                 "payload" => %{"event" => "INSERT", "payload" => payload, "type" => "broadcast"},
                 "ref" => nil,
                 "topic" => ^topic
               } = message

        id = fixture.id

        assert payload == %{
                 "value" => "something",
                 "id" => id
               }
      end

      test "payload including id", %{tenant: tenant} do
        start_link_supervised!(
          {ReplicationConnection, %ReplicationConnection{tenant_id: tenant.external_id, monitored_pid: self()}},
          restart: :transient
        )

        topic = random_string()
        tenant_topic = Tenants.tenant_topic(tenant.external_id, topic, false)
        subscribe(tenant_topic, topic)

        payload = %{"value" => "something", "id" => "123456"}

        message_fixture(tenant, %{
          "topic" => topic,
          "private" => true,
          "event" => "INSERT",
          "payload" => payload
        })

        assert_receive {:socket_push, :text, data}, 500
        message = data |> IO.iodata_to_binary() |> Jason.decode!()

        assert %{
                 "event" => "broadcast",
                 "payload" => %{"event" => "INSERT", "payload" => ^payload, "type" => "broadcast"},
                 "ref" => nil,
                 "topic" => ^topic
               } = message
      end

      test "fails on existing replication slot", %{tenant: tenant} do
        {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
        name = "supabase_realtime_messages_replication_slot_test"

        Postgrex.query!(db_conn, "SELECT pg_create_logical_replication_slot($1, 'test_decoding')", [name])

        assert {:error, {:shutdown, "Temporary Replication slot already exists and in use"}} =
                 ReplicationConnection.start(tenant, self())

        Postgrex.query!(db_conn, "SELECT pg_drop_replication_slot($1)", [name])
      end

      test "times out when init takes too long", %{tenant: tenant} do
        expect(ReplicationConnection, :init, 1, fn arg ->
          :timer.sleep(1000)
          call_original(ReplicationConnection, :init, [arg])
        end)

        {:error, :timeout} = ReplicationConnection.start(tenant, self(), 100)
      end

      test "handle standby connections exceeds max_wal_senders", %{tenant: tenant} do
        opts = Database.from_tenant(tenant, "realtime_test", :stop) |> Database.opts()

        # This creates a loop of errors that occupies all WAL senders and lets us test the error handling
        pids =
          for i <- 0..4 do
            replication_slot_opts =
              %PostgresReplication{
                connection_opts: opts,
                table: :all,
                output_plugin: "pgoutput",
                output_plugin_options: [],
                handler_module: TestHandler,
                publication_name: "test_#{i}_publication",
                replication_slot_name: "test_#{i}_slot"
              }

            {:ok, pid} = PostgresReplication.start_link(replication_slot_opts)
            pid
          end

        on_exit(fn ->
          Enum.each(pids, &Process.exit(&1, :kill))
          Process.sleep(2000)
        end)

        assert {:error, :max_wal_senders_reached} = ReplicationConnection.start(tenant, self())
      end
    end
  end

  describe "whereis/1" do
    @tag skip:
           "We are using a GenServer wrapper so the pid returned is not the same as the ReplicationConnection for now"
    test "returns pid if exists", %{tenant: tenant} do
      {:ok, pid} = ReplicationConnection.start(tenant, self())
      assert ReplicationConnection.whereis(tenant.external_id) == pid
      Process.exit(pid, :shutdown)
    end

    test "returns nil if not exists" do
      assert ReplicationConnection.whereis(random_string()) == nil
    end
  end

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {event, measures, metadata})

  describe "telemetry events" do
    setup do
      :telemetry.detach(__MODULE__)

      :telemetry.attach(
        __MODULE__,
        [:realtime, :tenants, :broadcast_from_database],
        &__MODULE__.handle_telemetry/4,
        pid: self()
      )
    end

    test "receives telemetry event", %{tenant: %{external_id: external_id} = tenant} do
      start_link_supervised!(
        {ReplicationConnection, %ReplicationConnection{tenant_id: external_id, monitored_pid: self()}},
        restart: :transient
      )

      topic = random_string()
      tenant_topic = Tenants.tenant_topic(external_id, topic, false)
      subscribe(tenant_topic, topic)

      message_fixture(tenant, %{
        "topic" => topic,
        "private" => true,
        "event" => "INSERT",
        "payload" => %{"value" => random_string()}
      })

      assert_receive {:socket_push, :text, data}
      message = data |> IO.iodata_to_binary() |> Jason.decode!()

      assert %{"event" => "broadcast", "payload" => _, "ref" => nil, "topic" => ^topic} = message

      assert_receive {[:realtime, :tenants, :broadcast_from_database],
                      %{latency_committed_at: latency_committed_at, latency_inserted_at: latency_inserted_at},
                      %{tenant: ^external_id}}

      assert latency_committed_at
      assert latency_inserted_at
    end
  end

  defmodule TestHandler do
    @behaviour PostgresReplication.Handler
    import PostgresReplication.Protocol
    alias PostgresReplication.Protocol.KeepAlive

    @impl true
    def call(message, _metadata) when is_write(message) do
      :noreply
    end

    def call(message, _metadata) when is_keep_alive(message) do
      reply =
        case parse(message) do
          %KeepAlive{reply: :now, wal_end: wal_end} ->
            wal_end = wal_end + 1
            standby(wal_end, wal_end, wal_end, :now)

          _ ->
            hold()
        end

      {:reply, reply}
    end

    def call(_, _), do: :noreply
  end

  defp subscribe(tenant_topic, topic) do
    fastlane =
      RealtimeWeb.RealtimeChannel.MessageDispatcher.fastlane_metadata(
        self(),
        Phoenix.Socket.V1.JSONSerializer,
        topic,
        :warning,
        "tenant_id"
      )

    Endpoint.subscribe(tenant_topic, metadata: fastlane)
  end
end
