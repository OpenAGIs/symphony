defmodule SymphonyElixir.CACerts do
  @moduledoc false

  require Logger

  @fallback_paths [
    "/etc/ssl/cert.pem",
    "/opt/homebrew/etc/openssl@3/cert.pem",
    "/usr/local/etc/openssl@3/cert.pem"
  ]

  @spec ensure_loaded() :: :ok
  def ensure_loaded do
    ensure_loaded_with(&:public_key.cacerts_load/0, &load_from_paths/1, &Logger.warning/1)
  end

  @doc false
  @spec ensure_loaded_with(
          (-> :ok | {:error, term()}),
          ([Path.t()] -> {:ok, Path.t()} | {:error, term()}),
          (String.t() -> term())
        ) :: :ok
  def ensure_loaded_with(cacerts_loader, path_loader, warn_fun)
      when is_function(cacerts_loader, 0) and is_function(path_loader, 1) and
             is_function(warn_fun, 1) do
    case cacerts_loader.() do
      :ok ->
        :ok

      {:error, :no_cacerts_found} ->
        case path_loader.(fallback_paths()) do
          {:ok, path} ->
            warn_fun.("Loaded CA certificates from fallback path #{path}")
            :ok

          {:error, reason} ->
            raise "failed to load CA certificates: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "failed to load CA certificates: #{inspect(reason)}"
    end
  end

  @doc false
  @spec load_from_paths([Path.t()]) :: {:ok, Path.t()} | {:error, term()}
  def load_from_paths(paths) when is_list(paths) do
    paths
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> do_load_from_paths({:error, :no_cacerts_found})
  end

  defp fallback_paths do
    [System.get_env("SSL_CERT_FILE") | @fallback_paths]
    |> Enum.reject(&is_nil/1)
  end

  defp do_load_from_paths([path | rest], _last_error) do
    case :public_key.cacerts_load(String.to_charlist(path)) do
      :ok -> {:ok, path}
      {:error, reason} -> do_load_from_paths(rest, {:error, reason})
    end
  end

  defp do_load_from_paths([], last_error), do: last_error
end
