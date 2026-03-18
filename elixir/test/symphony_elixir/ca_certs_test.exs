defmodule SymphonyElixir.CACertsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CACerts

  setup do
    had_cacerts? = :public_key.cacerts_clear()

    on_exit(fn ->
      :public_key.cacerts_clear()

      if had_cacerts? do
        CACerts.ensure_loaded()
      end
    end)

    :ok
  end

  test "loads certificates from the first valid fallback path" do
    cert_path =
      [
        System.get_env("SSL_CERT_FILE"),
        "/etc/ssl/cert.pem",
        "/opt/homebrew/etc/openssl@3/cert.pem",
        "/usr/local/etc/openssl@3/cert.pem"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.find(&File.regular?/1)

    assert is_binary(cert_path)
    assert {:ok, ^cert_path} = CACerts.load_from_paths(["/missing/cert.pem", cert_path])
    assert :public_key.cacerts_get() != []
  end

  test "returns the last load error when no fallback path works" do
    assert {:error, :enoent} =
             CACerts.load_from_paths(["/missing/one.pem", "/missing/two.pem"])
  end

  test "ensure_loaded_with handles ok, fallback, and error paths" do
    original_ssl_cert_file = System.get_env("SSL_CERT_FILE")

    on_exit(fn ->
      if is_nil(original_ssl_cert_file) do
        System.delete_env("SSL_CERT_FILE")
      else
        System.put_env("SSL_CERT_FILE", original_ssl_cert_file)
      end
    end)

    System.delete_env("SSL_CERT_FILE")

    assert :ok =
             CACerts.ensure_loaded_with(
               fn -> :ok end,
               fn _paths -> flunk("fallback loader should not run when cacerts are already loaded") end,
               fn _message -> flunk("warning callback should not run when cacerts are already loaded") end
             )

    assert :ok =
             CACerts.ensure_loaded_with(
               fn -> {:error, :no_cacerts_found} end,
               fn paths ->
                 send(self(), {:fallback_paths, paths})
                 {:ok, List.first(paths)}
               end,
               fn message ->
                 send(self(), {:warning, message})
                 :ok
               end
             )

    assert_received {:fallback_paths, fallback_paths}
    assert Enum.all?(fallback_paths, &is_binary/1)
    refute Enum.any?(fallback_paths, &is_nil/1)
    assert_received {:warning, "Loaded CA certificates from fallback path " <> _path}

    assert_raise RuntimeError, ~r/failed to load CA certificates: :enoent/, fn ->
      CACerts.ensure_loaded_with(
        fn -> {:error, :no_cacerts_found} end,
        fn _paths -> {:error, :enoent} end,
        fn _message -> :ok end
      )
    end

    assert_raise RuntimeError, ~r/failed to load CA certificates: :boom/, fn ->
      CACerts.ensure_loaded_with(
        fn -> {:error, :boom} end,
        fn _paths -> {:ok, "/unused"} end,
        fn _message -> :ok end
      )
    end
  end
end
