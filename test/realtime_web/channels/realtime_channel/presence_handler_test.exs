defmodule RealtimeWeb.RealtimeChannel.PresenceHandlerTest do
  use Realtime.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog
  import Generators

  alias Phoenix.Socket.Broadcast
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.BroadcastPolicies
  alias Realtime.Tenants.Authorization.Policies.PresencePolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.RealtimeChannel.PresenceHandler

  setup [:initiate_tenant]

  describe "handle/2" do
    test "with true policy and is private, user can track their presence and changes", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()

      socket =
        socket_fixture(tenant, topic, key, %Policies{presence: %PresencePolicies{read: true, write: true}})

      PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
    end

    test "when tracking already existing user, metadata updated", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()

      socket =
        socket_fixture(tenant, topic, key, %Policies{presence: %PresencePolicies{read: true, write: true}})

      assert {:reply, :ok, socket} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      payload = %{"event" => "track", "payload" => %{"content" => random_string()}}
      assert {:reply, :ok, _socket} = PresenceHandler.handle(payload, db_conn, socket)

      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
      refute_receive :_
    end

    test "with false policy and is public, user can track their presence and changes", %{tenant: tenant, topic: topic} do
      key = random_string()

      socket =
        socket_fixture(
          tenant,
          topic,
          key,
          %Policies{presence: %PresencePolicies{read: false, write: false}},
          false
        )

      assert {:reply, :ok, _socket} = PresenceHandler.handle(%{"event" => "track"}, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)
    end

    test "user can untrack when they want", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      key = random_string()

      socket =
        socket_fixture(tenant, topic, key, %Policies{presence: %PresencePolicies{read: true, write: true}})

      assert {:reply, :ok, socket} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
      topic = "realtime:#{topic}"
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: joins, leaves: %{}}}
      assert Map.has_key?(joins, key)

      assert {:reply, :ok, _socket} = PresenceHandler.handle(%{"event" => "untrack"}, db_conn, socket)
      assert_receive %Broadcast{topic: ^topic, event: "presence_diff", payload: %{joins: %{}, leaves: leaves}}
      assert Map.has_key?(leaves, key)
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]
    test "only checks write policies once on private channels", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      expect(Authorization, :get_write_authorizations, 1, fn conn, db_conn, auth_context ->
        call_original(Authorization, :get_write_authorizations, [conn, db_conn, auth_context])
      end)

      key = random_string()
      socket = socket_fixture(tenant, topic, key)
      topic = "realtime:#{topic}"

      for _ <- 1..100, reduce: socket do
        socket ->
          assert {:reply, :ok, socket} =
                   PresenceHandler.handle(
                     %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                     db_conn,
                     socket
                   )

          assert_receive %Broadcast{topic: ^topic, event: "presence_diff"}
          socket
      end
    end

    @tag policies: [:authenticated_read_broadcast_and_presence, :broken_write_presence]
    test "handle failing rls policy", %{tenant: tenant, topic: topic, db_conn: db_conn} do
      expect(Authorization, :get_write_authorizations, 1, fn conn, db_conn, auth_context ->
        call_original(Authorization, :get_write_authorizations, [conn, db_conn, auth_context])
      end)

      key = random_string()
      socket = socket_fixture(tenant, topic, key)
      topic = "realtime:#{topic}"

      log =
        capture_log(fn ->
          assert {:reply, :error, _} =
                   PresenceHandler.handle(
                     %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                     db_conn,
                     socket
                   )

          refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}, 1000
        end)

      assert log =~ "RlsPolicyError"
    end

    test "does not check write policies once on public channels", %{tenant: tenant, topic: topic} do
      reject(&Authorization.get_write_authorizations/3)

      key = random_string()

      socket =
        socket_fixture(tenant, topic, key, %Policies{broadcast: %BroadcastPolicies{read: false}}, false)

      topic = "realtime:#{topic}"

      for _ <- 1..100, reduce: socket do
        socket ->
          assert {:reply, :ok, socket} =
                   PresenceHandler.handle(
                     %{"event" => "track", "payload" => %{"metadata" => random_string()}},
                     socket
                   )

          assert_receive %Broadcast{topic: ^topic, event: "presence_diff"}
          socket
      end
    end

    test "logs out non recognized events" do
      socket = %Phoenix.Socket{joined: true}

      log =
        capture_log(fn ->
          assert {:reply, :error, %Phoenix.Socket{}} = PresenceHandler.handle(%{"event" => "unknown"}, nil, socket)
        end)

      assert log =~ "UnknownPresenceEvent"
    end

    test "socket with presence enabled false will ignore presence events in public channel", %{
      tenant: tenant,
      topic: topic
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies, false, false)

      assert {:reply, :ok, _socket} = PresenceHandler.handle(%{"event" => "track"}, socket)
      topic = "realtime:#{topic}"
      refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}
    end

    test "socket with presence enabled false will ignore presence events in private channel", %{
      tenant: tenant,
      topic: topic,
      db_conn: db_conn
    } do
      key = random_string()
      policies = %Policies{presence: %PresencePolicies{read: true, write: true}}
      socket = socket_fixture(tenant, topic, key, policies, false, false)

      assert {:reply, :ok, _socket} = PresenceHandler.handle(%{"event" => "track"}, db_conn, socket)
      topic = "realtime:#{topic}"
      refute_receive %Broadcast{topic: ^topic, event: "presence_diff"}
    end
  end

  defp initiate_tenant(context) do
    tenant = Containers.checkout_tenant(run_migrations: true)
    # Warm cache to avoid Cachex and Ecto.Sandbox ownership issues
    Cachex.put!(Realtime.Tenants.Cache, {{:get_tenant_by_external_id, 1}, [tenant.external_id]}, {:cached, tenant})

    {:ok, db_conn} = Connect.lookup_or_start_connection(tenant.external_id)
    assert Connect.ready?(tenant.external_id)

    topic = random_string()
    Endpoint.subscribe("realtime:#{topic}")
    if policies = context[:policies], do: create_rls_policies(db_conn, policies, %{topic: topic})

    {:ok, tenant: tenant, db_conn: db_conn, topic: topic}
  end

  defp socket_fixture(
         tenant,
         topic,
         presence_key,
         policies \\ %Policies{
           broadcast: %BroadcastPolicies{read: true},
           presence: %PresencePolicies{read: true, write: nil}
         },
         private? \\ true,
         enabled? \\ true
       ) do
    claims = %{sub: random_string(), role: "authenticated", exp: Joken.current_time() + 1_000}
    signer = Joken.Signer.create("HS256", "secret")

    jwt = Joken.generate_and_sign!(%{}, claims, signer)

    authorization_context =
      Authorization.build_authorization_params(%{
        tenant_id: tenant.external_id,
        topic: topic,
        jwt: jwt,
        claims: claims,
        headers: [{"header-1", "value-1"}],
        role: claims.role
      })

    tenant_topic = "realtime:#{topic}"
    self_broadcast = true

    %Phoenix.Socket{
      joined: true,
      topic: tenant_topic,
      assigns: %{
        tenant_topic: tenant_topic,
        self_broadcast: self_broadcast,
        policies: policies,
        authorization_context: authorization_context,
        private?: private?,
        presence_key: presence_key,
        presence_enabled?: enabled?
      }
    }
  end
end
