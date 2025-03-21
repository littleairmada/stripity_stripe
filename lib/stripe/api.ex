defmodule Stripe.API do
  @moduledoc """
  Low-level utilities for interacting with the Stripe API.

  Usually the utilities in `Stripe.Request` are a better way to write custom interactions with
  the API.
  """
  alias Stripe.{Config, Error}

  @callback oauth_request(method, String.t(), map) :: {:ok, map}

  @type method :: :get | :post | :put | :delete | :patch
  @type headers :: %{String.t() => String.t()} | %{}
  @type body :: iodata() | {:multipart, list()}
  @typep http_success :: {:ok, integer, [{String.t(), String.t()}], String.t()}
  @typep http_failure :: {:error, term}

  @pool_name __MODULE__
  @api_version "2022-11-15"

  @idempotency_key_header "Idempotency-Key"

  @default_max_attempts 3
  @default_base_backoff 500
  @default_max_backoff 2_000

  @doc """
  In config.exs your implicit or explicit configuration is:
    config :stripity_stripe,
      json_library: Poison # defaults to Jason but can be configured to Poison
  """
  @spec json_library() :: module
  def json_library() do
    Config.resolve(:json_library, Jason)
  end

  def supervisor_children do
    if use_pool?() do
      [:hackney_pool.child_spec(@pool_name, get_pool_options())]
    else
      []
    end
  end

  @spec get_pool_options() :: Keyword.t()
  defp get_pool_options() do
    Config.resolve(:pool_options)
  end

  @spec get_base_url() :: String.t()
  defp get_base_url() do
    Config.resolve(:api_base_url)
  end

  @spec get_upload_url() :: String.t()
  defp get_upload_url() do
    Config.resolve(:api_upload_url)
  end

  @spec get_default_api_key() :: String.t()
  defp get_default_api_key() do
    # if no API key is set default to `""` which will raise a Stripe API error
    Config.resolve(:api_key, "")
  end

  @spec get_api_version() :: String.t()
  defp get_api_version() do
    Config.resolve(:api_version, @api_version)
  end

  @spec use_pool?() :: boolean
  defp use_pool?() do
    Config.resolve(:use_connection_pool)
  end

  @spec http_module() :: module
  defp http_module() do
    Config.resolve(:http_module, :hackney)
  end

  @spec retry_config() :: Keyword.t()
  defp retry_config() do
    Config.resolve(:retries, [])
  end

  @doc """
  Checks if an error is a problem that we should retry on. This includes both
  socket errors that may represent an intermittent problem and some special
  HTTP statuses.
  """
  @spec should_retry?(
          http_success | http_failure,
          attempts :: non_neg_integer,
          config :: Keyword.t()
        ) :: boolean
  def should_retry?(response, attempts \\ 0, config \\ []) do
    max_attempts = Keyword.get(config, :max_attempts) || @default_max_attempts

    if attempts >= max_attempts do
      false
    else
      retry_response?(response)
    end
  end

  @doc """
  A low level utility function to generate a new idempotency key for
  `#{@idempotency_key_header}` request header value.
  """
  @spec generate_idempotency_key() :: binary
  def generate_idempotency_key do
    binary = <<
      System.system_time(:nanosecond)::64,
      :erlang.phash2({node(), self()}, 16_777_216)::24,
      System.unique_integer([:positive])::32
    >>

    Base.hex_encode32(binary, case: :lower, padding: false)
  end

  @spec add_common_headers(headers) :: headers
  defp add_common_headers(existing_headers) do
    Map.merge(existing_headers, %{
      "Accept" => "application/json; charset=utf8",
      "Accept-Encoding" => "gzip",
      "Connection" => "keep-alive"
    })
  end

  @spec add_default_headers(headers) :: headers
  defp add_default_headers(existing_headers) do
    existing_headers = add_common_headers(existing_headers)

    case Map.has_key?(existing_headers, "Content-Type") do
      false -> existing_headers |> Map.put("Content-Type", "application/x-www-form-urlencoded")
      true -> existing_headers
    end
  end

  @spec add_multipart_form_headers(headers) :: headers
  defp add_multipart_form_headers(existing_headers) do
    existing_headers
    |> Map.put("Content-Type", "multipart/form-data")
  end

  @spec add_idempotency_headers(headers, method) :: headers
  defp add_idempotency_headers(existing_headers, method)
       when method in [:get, :head, :put, :delete] do
    existing_headers
  end

  defp add_idempotency_headers(existing_headers, _method) do
    # By using `Map.put_new/3` instead of `Map.put/3`, we allow users to
    # provide their own idempotency key.
    existing_headers
    |> Map.put_new(@idempotency_key_header, generate_idempotency_key())
  end

  @spec maybe_add_auth_header_oauth(headers, String.t(), String.t() | nil) :: headers
  defp maybe_add_auth_header_oauth(headers, "deauthorize", api_key),
    do: add_auth_header(headers, api_key)

  defp maybe_add_auth_header_oauth(headers, _endpoint, _api_key), do: headers

  @spec add_auth_header(headers, String.t() | nil) :: headers
  defp add_auth_header(existing_headers, api_key) do
    api_key = fetch_api_key(api_key)
    Map.put(existing_headers, "Authorization", "Bearer #{api_key}")
  end

  @spec fetch_api_key(String.t() | nil) :: String.t()
  defp fetch_api_key(api_key) do
    case api_key do
      key when is_binary(key) -> key
      _ -> get_default_api_key()
    end
  end

  @spec add_connect_header(headers, String.t() | nil) :: headers
  defp add_connect_header(existing_headers, nil), do: existing_headers

  defp add_connect_header(existing_headers, account_id) do
    Map.put(existing_headers, "Stripe-Account", account_id)
  end

  @spec add_api_version(headers, String.t() | nil) :: headers
  defp add_api_version(existing_headers, nil),
    do: add_api_version(existing_headers, get_api_version())

  defp add_api_version(existing_headers, api_version) do
    Map.merge(existing_headers, %{
      "User-Agent" => "Stripe/v1 stripe-elixir/#{api_version}",
      "Stripe-Version" => api_version
    })
  end

  @spec add_default_options(list) :: list
  defp add_default_options(opts) do
    [:with_body | opts]
  end

  @spec add_pool_option(list) :: list
  defp add_pool_option(opts) do
    if use_pool?() do
      [{:pool, @pool_name} | opts]
    else
      opts
    end
  end

  @spec add_options_from_config(list) :: list
  defp add_options_from_config(opts) do
    if is_list(Stripe.Config.resolve(:hackney_opts)) do
      opts ++ Stripe.Config.resolve(:hackney_opts)
    else
      opts
    end
  end

  @doc """
  A low level utility function to make a direct request to the Stripe API

  ## Setting the api key

      request(%{}, :get, "/customers", %{}, api_key: "bogus key")

  ## Setting api version

  The api version defaults to #{@api_version} but a custom version can be passed
  in as follows:

      request(%{}, :get, "/customers", %{}, api_version: "2018-11-04")

  ## Connect Accounts

  If you'd like to make a request on behalf of another Stripe account
  utilizing the Connect program, you can pass the other Stripe account's
  ID to the request function as follows:

      request(%{}, :get, "/customers", %{}, connect_account: "acc_134151")

  """
  @spec request(map, method, String.t(), headers, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  def request(body, :get, endpoint, headers, opts) do
    {expansion, opts} = Keyword.pop(opts, :expand)
    base_url = get_base_url()

    req_url =
      body
      |> Stripe.Util.map_keys_to_atoms()
      |> add_object_expansion(expansion)
      |> Stripe.URI.encode_query()
      |> prepend_url("#{base_url}#{endpoint}")

    perform_request(req_url, :get, "", headers, opts)
  end

  def request(body, method, endpoint, headers, opts) do
    {expansion, opts} = Keyword.pop(opts, :expand)
    {idempotency_key, opts} = Keyword.pop(opts, :idempotency_key)

    base_url = get_base_url()
    req_url = add_object_expansion("#{base_url}#{endpoint}", expansion)
    headers = add_idempotency_header(idempotency_key, headers, method)

    req_body =
      body
      |> Stripe.Util.map_keys_to_atoms()
      |> Stripe.URI.encode_query()

    perform_request(req_url, method, req_body, headers, opts)
  end

  @doc """
  A low level utility function to make a direct request to the files Stripe API
  """
  @spec request_file_upload(map, method, String.t(), headers, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  def request_file_upload(body, :post, endpoint, headers, opts) do
    base_url = get_upload_url()
    req_url = base_url <> endpoint

    req_headers =
      headers
      |> add_multipart_form_headers()

    parts =
      body
      |> Enum.map(fn {key, value} ->
        {Stripe.Util.multipart_key(key), value}
      end)

    perform_request(req_url, :post, {:multipart, parts}, req_headers, opts)
  end

  def request_file_upload(body, method, endpoint, headers, opts) do
    base_url = get_upload_url()
    req_url = base_url <> endpoint

    req_body =
      body
      |> Stripe.Util.map_keys_to_atoms()
      |> Stripe.URI.encode_query()

    perform_request(req_url, method, req_body, headers, opts)
  end

  @doc """
  A low level utility function to make an OAuth request to the Stripe API
  """
  @spec oauth_request(method, String.t(), map, String.t() | nil) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  def oauth_request(method, endpoint, body, api_key \\ nil, opts \\ []) do
    base_url = "https://connect.stripe.com/oauth/"
    req_url = base_url <> endpoint
    req_body = Stripe.URI.encode_query(body)
    {api_version, _opts} = Keyword.pop(opts, :api_version)

    req_headers =
      %{}
      |> add_default_headers()
      |> maybe_add_auth_header_oauth(endpoint, api_key)
      |> add_api_version(api_version)
      |> add_idempotency_headers(method)

    req_opts =
      []
      |> add_default_options()
      |> add_pool_option()
      |> add_options_from_config()

    do_perform_request(method, req_url, req_headers, req_body, req_opts)
  end

  @spec perform_request(String.t(), method, body, headers, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  defp perform_request(req_url, method, body, headers, opts) do
    {connect_account_id, opts} = Keyword.pop(opts, :connect_account)
    {api_version, opts} = Keyword.pop(opts, :api_version)
    {api_key, opts} = Keyword.pop(opts, :api_key)

    req_headers =
      headers
      |> add_default_headers()
      |> add_auth_header(api_key)
      |> add_connect_header(connect_account_id)
      |> add_api_version(api_version)
      |> add_idempotency_headers(method)

    req_opts =
      opts
      |> add_default_options()
      |> add_pool_option()
      |> add_options_from_config()

    do_perform_request(method, req_url, req_headers, body, req_opts)
  end

  @spec do_perform_request(method, String.t(), headers, body, list) ::
          {:ok, map} | {:error, Stripe.Error.t()}
  defp do_perform_request(method, url, headers, body, opts) do
    do_perform_request_and_retry(method, url, headers, body, opts, {:attempts, 0})
  end

  @spec do_perform_request_and_retry(
          method,
          String.t(),
          headers,
          body,
          list,
          {:attempts, non_neg_integer} | {:response, http_success | http_failure}
        ) :: {:ok, map} | {:error, Stripe.Error.t()}
  defp do_perform_request_and_retry(_method, _url, _headers, _body, _opts, {:response, response}) do
    handle_response(response)
  end

  defp do_perform_request_and_retry(method, url, headers, body, opts, {:attempts, attempts}) do
    start_metadata = %{url: url, method: method, attempts: attempts, headers: headers}

    response =
      :telemetry.span(~w[stripe request]a, start_metadata, fn ->
        case http_module().request(method, url, Map.to_list(headers), body, opts) do
          {:ok, status, _, _} = resp ->
            {resp, Map.merge(start_metadata, %{status: status})}

          error ->
            {error, %{}}
        end
      end)

    do_perform_request_and_retry(
      method,
      url,
      headers,
      body,
      opts,
      add_attempts(headers, response, attempts, retry_config())
    )
  end

  @spec add_attempts(headers, http_success | http_failure, non_neg_integer, Keyword.t()) ::
          {:attempts, non_neg_integer} | {:response, http_success | http_failure}
  defp add_attempts(%{@idempotency_key_header => _}, response, attempts, retry_config) do
    # only retry if allowed Stripe idempotency method
    if should_retry?(response, attempts, retry_config) do
      attempts
      |> backoff(retry_config)
      |> :timer.sleep()

      {:attempts, attempts + 1}
    else
      {:response, response}
    end
  end

  defp add_attempts(_headers, response, _attempts, _retry_config) do
    {:response, response}
  end

  @doc """
  Returns backoff in milliseconds.
  """
  @spec backoff(attempts :: non_neg_integer, config :: Keyword.t()) :: non_neg_integer
  def backoff(attempts, config) do
    base_backoff = Keyword.get(config, :base_backoff) || @default_base_backoff
    max_backoff = Keyword.get(config, :max_backoff) || @default_max_backoff

    (base_backoff * :math.pow(2, attempts))
    |> min(max_backoff)
    |> backoff_jitter()
    |> max(base_backoff)
    |> trunc()
  end

  @spec backoff_jitter(float) :: float
  defp backoff_jitter(n) do
    # Apply some jitter by randomizing the value in the range of (n / 2) to n
    n * (0.5 * (1 + :rand.uniform()))
  end

  @spec retry_response?(http_success | http_failure) :: boolean
  # 409 conflict
  defp retry_response?({:error, 409, _headers, _body}), do: true
  # https://github.com/beam-community/stripity_stripe/issues/686
  defp retry_response?({:error, 429, _headers, _body}), do: true
  # Destination refused the connection, the connection was reset, or a
  # variety of other connection failures. This could occur from a single
  # saturated server, so retry in case it's intermittent.
  defp retry_response?({:error, :econnrefused}), do: true
  # Retry on timeout-related problems (either on open or read).
  defp retry_response?({:error, :connect_timeout}), do: true
  defp retry_response?({:error, :timeout}), do: true
  defp retry_response?(_response), do: false

  @spec handle_response(http_success | http_failure) :: {:ok, map} | {:error, Stripe.Error.t()}
  defp handle_response({:ok, status, headers, body}) when status >= 200 and status <= 299 do
    decoded_body =
      body
      |> decompress_body(headers)
      |> json_library().decode!()

    {:ok, decoded_body}
  end

  defp handle_response({:ok, status, headers, body}) when status >= 300 and status <= 599 do
    request_id =
      Enum.find_value(headers, fn
        {"Request-Id", request_id} -> request_id
        _header -> nil
      end)

    error =
      case json_library().decode(body) do
        {:ok, %{"error_description" => _} = api_error} ->
          Error.from_stripe_error(status, api_error, request_id)

        {:ok, %{"error" => api_error}} ->
          Error.from_stripe_error(status, api_error, request_id)

        {:error, _} ->
          # e.g. if the body is empty
          Error.from_stripe_error(status, nil, request_id)
      end

    {:error, error}
  end

  defp handle_response({:error, reason}) do
    error = Error.from_hackney_error(reason)
    {:error, error}
  end

  defp decompress_body(body, headers) do
    headers_dict = :hackney_headers.new(headers)

    case :hackney_headers.get_value("Content-Encoding", headers_dict) do
      "gzip" -> :zlib.gunzip(body)
      "deflate" -> :zlib.unzip(body)
      _ -> body
    end
  end

  defp prepend_url("", url), do: url
  defp prepend_url(query, url), do: "#{url}?#{query}"

  defp add_object_expansion(query, expansion) when is_map(query) and is_list(expansion) do
    query |> Map.put(:expand, expansion)
  end

  defp add_object_expansion(url, expansion) when is_list(expansion) do
    expansion
    |> Enum.map(&"expand[]=#{&1}")
    |> Enum.join("&")
    |> prepend_url(url)
  end

  defp add_object_expansion(url, _), do: url

  defp add_idempotency_header(nil, headers, _), do: headers

  defp add_idempotency_header(idempotency_key, headers, :post) do
    Map.put(headers, "Idempotency-Key", idempotency_key)
  end

  defp add_idempotency_header(_, headers, _), do: headers
end
