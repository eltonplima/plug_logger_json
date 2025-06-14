defmodule Plug.LoggerJSONTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  import ExUnit.CaptureIO
  require Logger

  defmodule MyDebugPlug do
    use Plug.Builder

    plug(Plug.LoggerJSON, log: :debug, extra_attributes_fn: &__MODULE__.extra_attributes/1)

    plug(Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Poison
    )

    plug(:passthrough)

    defp passthrough(conn, _) do
      Plug.Conn.send_resp(conn, 200, "Passthrough")
    end

    def extra_attributes(conn) do
      map = %{
        "user_id" => get_in(conn.assigns, [:user, :user_id]),
        "other_id" => get_in(conn.private, [:private_resource, :id]),
        "should_not_appear" => conn.private[:does_not_exist]
      }

      map
      |> Enum.filter(fn {_key, value} -> value !== nil end)
      |> Enum.into(%{})
    end
  end

  defmodule MyInfoPlug do
    use Plug.Builder

    plug(Plug.LoggerJSON, log: :info)

    plug(Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Poison
    )

    plug(:passthrough)

    defp passthrough(conn, _) do
      Plug.Conn.send_resp(conn, 200, "Passthrough")
    end
  end

  defmodule MyInfoPlugWithIncludeDebugLogging do
    use Plug.Builder

    plug(Plug.LoggerJSON, log: :info, include_debug_logging: true)

    plug(Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Poison
    )

    plug(:passthrough)

    defp passthrough(conn, _) do
      Plug.Conn.send_resp(conn, 200, "Passthrough")
    end
  end

  # Setup to preserve original config and restore it after tests
  setup do
    original_config = Application.get_env(:plug_logger_json, :filtered_keys)

    on_exit(fn ->
      if original_config do
        Application.put_env(:plug_logger_json, :filtered_keys, original_config)
      else
        Application.delete_env(:plug_logger_json, :filtered_keys)
      end
    end)

    %{original_config: original_config}
  end

  # Test helpers
  defp remove_colors(message) do
    message
    |> String.replace("\e[36m", "")
    |> String.replace("\e[31m", "")
    |> String.replace("\e[22m", "")
    |> String.replace("\n\e[0m", "")
    |> String.replace("{\"requ", "{\"requ")
  end

  defp call(conn, plug) do
    get_log(fn -> plug.call(conn, []) end)
  end

  defp get_log(func) do
    data =
      capture_io(:user, fn ->
        Process.put(:get_log, func.())
        Logger.flush()
      end)

    {Process.get(:get_log), data}
  end

  # New helper functions for better readability
  defp make_request_and_get_log(conn, plug \\ MyDebugPlug) do
    {_conn, message} = call(conn, plug)
    message |> remove_colors() |> Poison.decode!()
  end

  defp assert_common_log_fields(log_map) do
    assert log_map["date_time"]
    assert log_map["duration"]
    assert log_map["log_type"] == "http"
  end

  defp assert_default_values(log_map) do
    assert log_map["api_version"] == "N/A"
    assert log_map["client_ip"] == "N/A"
    assert log_map["client_version"] == "N/A"
    assert log_map["handler"] == "N/A"
    assert log_map["request_id"] == nil
  end

  describe "basic request logging" do
    test "logs GET request with no parameters or headers" do
      log_map =
        conn(:get, "/")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "GET"
      assert log_map["params"] == %{}
      assert log_map["path"] == "/"
      assert log_map["status"] == 200
    end

    test "logs GET request with query parameters and headers" do
      log_map =
        conn(:get, "/", fake_param: "1")
        |> put_req_header("authorization", "f3443890-6683-4a25-8094-f23cf10b72d0")
        |> put_req_header("content-type", "application/json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "GET"
      assert log_map["params"] == %{"fake_param" => "1"}
      assert log_map["path"] == "/"
      assert log_map["status"] == 200
    end

    test "logs POST request with JSON body" do
      json_payload = %{
        "reaction" => %{
          "reaction" => "other",
          "track_id" => "7550",
          "type" => "emoji",
          "user_id" => "a2e684ee-2e5f-4e4d-879a-bb253908eef3"
        }
      }

      log_map =
        conn(:post, "/", Poison.encode!(json_payload))
        |> put_req_header("content-type", "application/json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert_default_values(log_map)
      assert log_map["method"] == "POST"
      assert log_map["params"] == json_payload
      assert log_map["path"] == "/"
      assert log_map["status"] == 200
    end
  end

  describe "Phoenix integration" do
    test "logs handler information when Phoenix controller is present" do
      log_map =
        conn(:get, "/")
        |> put_private(:phoenix_controller, Plug.LoggerJSONTest)
        |> put_private(:phoenix_action, :show)
        |> put_private(:phoenix_format, "json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert log_map["handler"] == "Elixir.Plug.LoggerJSONTest#show"
      assert log_map["method"] == "GET"
      assert log_map["status"] == 200
    end
  end

  describe "client information extraction" do
    test "extracts client IP from X-Forwarded-For header" do
      log_map =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_private(:phoenix_controller, Plug.LoggerJSONTest)
        |> put_private(:phoenix_action, :show)
        |> put_private(:phoenix_format, "json")
        |> make_request_and_get_log()

      assert_common_log_fields(log_map)
      assert log_map["client_ip"] == "209.49.75.165"
      assert log_map["handler"] == "Elixir.Plug.LoggerJSONTest#show"
    end
  end

  describe "parameter filtering" do
    test "does not expose authorization headers in params" do
      log_map =
        conn(:get, "/")
        |> put_req_header("authorization", "f3443890-6683-4a25-8094-f23cf10b72d0")
        |> make_request_and_get_log()

      # Authorization headers aren't shown in debug mode params by default
      assert log_map["params"] == %{}
    end

    test "filters sensitive parameters" do
      # Set filtered_keys for this specific test
      Application.put_env(:plug_logger_json, :filtered_keys, ["password", "authorization"])

      log_map =
        conn(:post, "/", authorization: "secret-token", username: "test")
        |> make_request_and_get_log()

      assert log_map["params"]["authorization"] == "[FILTERED]"
      assert log_map["params"]["username"] == "test"
    end

    test "filters nested sensitive parameters" do
      Application.put_env(:plug_logger_json, :filtered_keys, ["password"])

      log_map =
        conn(:post, "/", %{user: %{password: "secret", username: "me"}})
        |> make_request_and_get_log()

      user_params = log_map["params"]["user"]
      assert user_params["password"] == "[FILTERED]"
      assert user_params["username"] == "me"
    end
  end

  describe "extra attributes" do
    test "includes custom attributes from assigns and private data" do
      log_map =
        conn(:get, "/")
        |> assign(:user, %{user_id: "1234"})
        |> put_private(:private_resource, %{id: "555"})
        |> make_request_and_get_log()

      assert log_map["user_id"] == "1234"
      assert log_map["other_id"] == "555"
      refute Map.has_key?(log_map, "should_not_appear")
    end
  end

  describe "special data types handling" do
    test "handles structs in parameters" do
      log_map =
        conn(:post, "/", %{photo: %Plug.Upload{}})
        |> make_request_and_get_log()

      expected_photo = %{"content_type" => nil, "filename" => nil, "path" => nil}
      assert log_map["params"]["photo"] == expected_photo
    end
  end

  describe "log level configurations" do
    test "excludes debug information when log level is info" do
      log_map =
        conn(:get, "/", fake_param: "1")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_req_header("x-client-version", "ios/1.5.4")
        |> make_request_and_get_log(MyInfoPlug)

      assert log_map["client_ip"] == nil
      assert log_map["client_version"] == nil
      assert log_map["params"] == nil
    end

    test "includes debug information when explicitly enabled for info level" do
      log_map =
        conn(:get, "/", fake_param: "1")
        |> put_req_header("x-forwarded-for", "209.49.75.165")
        |> put_req_header("x-client-version", "ios/1.5.4")
        |> make_request_and_get_log(MyInfoPlugWithIncludeDebugLogging)

      assert log_map["client_ip"] == "209.49.75.165"
      assert log_map["client_version"] == "ios/1.5.4"
      assert log_map["params"] == %{"fake_param" => "1"}
    end
  end

  describe "error logging" do
    test "logs runtime errors with stacktrace information" do
      stacktrace = [
        {Plug.LoggerJSONTest, :call, 2, [file: ~c"lib/test.ex", line: 10]},
        {Plug.Adapters.Cowboy.Handler, :upgrade, 4,
         [file: ~c"lib/plug/adapters/cowboy/handler.ex", line: 15]}
      ]

      message =
        capture_io(:user, fn ->
          Plug.LoggerJSON.log_error(:error, %RuntimeError{message: "oops"}, stacktrace)
          Logger.flush()
        end)

      log_map = message |> remove_colors() |> Poison.decode!()

      assert log_map["log_type"] == "error"
      assert log_map["message"] =~ "** (RuntimeError) oops"
      assert log_map["message"] =~ "lib/test.ex:10: Plug.LoggerJSONTest.call/2"
      assert log_map["request_id"] == nil
    end
  end
end
