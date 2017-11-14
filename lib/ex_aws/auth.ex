defmodule ExAws.Auth do
  import ExAws.Auth.Utils

  alias ExAws.Auth.Credentials
  alias ExAws.Auth.Signatures

  @moduledoc false

  def headers(http_method, url, service, config, headers, body) do
    datetime = :calendar.universal_time
    headers = [
      {"host", URI.parse(url).authority},
      {"x-amz-date", amz_date(datetime)} |
      headers
    ]
    |> handle_temp_credentials(config)

    auth_header = auth_header(
      http_method,
      url,
      headers,
      body,
      service |> service_name,
      datetime,
      config)

    [{"Authorization", auth_header} | headers ]
  end

  def headers_v2(http_method, url, service, config, headers, body) do
    datetime = :calendar.universal_time
    headers = [
      {"host", URI.parse(url).authority},
      {"date", Timex.now |> Timex.format!("{WDshort}, {D} {Mshort} {YYYY} {h24}:{m}:{s} {Z}")}
      | headers
    ]

    auth_header = auth_header_v2(
      http_method,
      url,
      headers,
      body,
      service |> service_name,
      datetime,
      config)

    [{"Authorization", auth_header} | headers]
  end

  def presigned_url(http_method, url, service, datetime, config, expires, query_params \\ []) do
    if service == :s3 && config[:s3_auth_version] == "2" do
      presigned_url_v2(http_method, url, service, datetime, config, expires, query_params)
    else
      presigned_url_v4(http_method, url, service, datetime, config, expires, query_params)
    end
  end

  def presigned_url_v4(http_method, url, service, datetime, config, expires, query_params \\ []) do
    service = service_name(service)
    headers = presigned_url_headers(url)

    org_query_params = query_params |> Enum.map(fn({k, v}) -> {to_string(k), v} end)
    amz_query_params = build_amz_query_params(service, datetime, config, expires)
    [org_query, amz_query] = [org_query_params, amz_query_params] |> Enum.map(&canonical_query_params/1)
    query_to_sign = org_query_params ++ amz_query_params |> canonical_query_params
    query_for_url = if Enum.any?(org_query_params), do: org_query <> "&" <> amz_query, else: amz_query

    uri = URI.parse(url)
    path = uri_encode(uri.path)
    signature = signature(http_method, path, query_to_sign, headers, nil, service, datetime, config)
    "#{uri.scheme}://#{uri.authority}#{path}?#{query_for_url}&X-Amz-Signature=#{signature}"
  end

  def presigned_url_v2(:get, url, :s3, _datetime, config, expires, _query_params \\ []) do
    expires = :os.system_time(:seconds) + expires

    string_to_sign = [
      "GET",
      "",
      "",
      inspect(expires),
      "/" <> url
    ]
    |> Enum.join("\n")

    signature = config[:secret_access_key]
                |> ExAws.Auth.Utils.hmac_sha(string_to_sign)
                |> Base.encode64
                |> uri_encode_v2

    uri = URI.parse(url)
    path = uri.path
    query_for_url = [
      "AWSAccessKeyId=" <> config[:access_key_id],
      "Expires=" <> inspect(expires),
      "Signature=" <> signature
    ]
    |> Enum.join("&")

    "#{path}?#{query_for_url}"
  end

  defp handle_temp_credentials(headers, %{security_token: token}) do
    [{"X-Amz-Security-Token", token} | headers]
  end
  defp handle_temp_credentials(headers, _), do: headers

  defp auth_header(http_method, url, headers, body, service, datetime, config) do
    uri = URI.parse(url)
    path = uri_encode(uri.path)
    query = if uri.query, do: uri.query |> URI.decode_query |> Enum.to_list |> canonical_query_params, else: ""
    signature = signature(http_method, path, query, headers, body, service, datetime, config)
    [
      "AWS4-HMAC-SHA256 Credential=", Credentials.generate_credential_v4(service, config, datetime), ",",
      "SignedHeaders=", signed_headers(headers), ",",
      "Signature=", signature
    ] |> IO.iodata_to_binary
  end

  defp auth_header_v2(http_method, url, headers, body, service, datetime, config) do
    uri = URI.parse(url)
    path = uri_encode(uri.path)
    query = if uri.query, do: uri.query |> URI.decode_query |> Enum.to_list |> canonical_query_params, else: ""
    signature = signature_v2(http_method, path, query, headers, body, service, datetime, config)
    [
      "AWS ",
      "#{config[:access_key_id]}:",
      signature
    ] |> IO.iodata_to_binary
  end

  defp signature(http_method, path, query, headers, body, service, datetime, config) do
    request = build_canonical_request(http_method, path, query, headers, body)
    string_to_sign = string_to_sign(request, service, datetime, config)

    Signatures.generate_signature_v4(service, config, datetime, string_to_sign)
  end

  defp signature_v2(http_method, path, query, headers, body, service, datetime, config) do
    request = build_canonical_request_v2(http_method, path, query, headers, body, datetime)

    Signatures.generate_signature_v2(service, config, datetime, request)
  end

  def build_canonical_request(http_method, path, query, headers, body) do
    http_method = http_method |> method_string |> String.upcase

    headers = headers |> canonical_headers
    header_string = headers
    |> Enum.map(fn {k, v} -> "#{k}:#{remove_dup_spaces(to_string(v))}" end)
    |> Enum.join("\n")

    signed_headers_list = headers
    |> Keyword.keys
    |> Enum.join(";")

    payload = case body do
      nil -> "UNSIGNED-PAYLOAD"
      _ -> ExAws.Auth.Utils.hash_sha256(body)
    end

    [
      http_method, "\n",
      path, "\n",
      query, "\n",
      header_string, "\n",
      "\n",
      signed_headers_list, "\n",
      payload
    ] |> IO.iodata_to_binary
  end

  def build_canonical_request_v2(http_method, path, query, headers, _body, _datetime) do
    http_method = http_method |> method_string |> String.upcase

    content_md5 = find_header_value(headers, "content-md5")
    content_type = if http_method == "PUT" do
      find_header_value(headers, "content-type", "application/octet-stream")
    else
      find_header_value(headers, "content-type")
    end
    date = find_header_value(headers, "date")

    headers = headers |> canonical_headers_v2
    header_string = headers
    |> Enum.map(fn {k, v} -> "#{k}:#{remove_dup_spaces(to_string(v))}" end)
    |> Enum.join("\n")

    resource_string = path <> canonical_query(query)

    [
      http_method, "\n",
      content_md5, "\n",
      content_type, "\n",
      date, "\n",
      header_string, "\n",
      resource_string
    ] |> IO.iodata_to_binary
  end

  defp find_header_value(headers, key, default \\ "") do
    header = Enum.find(headers, fn el ->
      elem(el, 0) == key
    end) || {nil, default}
    elem(header, 1)
  end

  defp canonical_query(""), do: ""
  defp canonical_query(query) do
    "?" <> query
    |> String.split("&")
    |> Enum.map(fn chunk ->
      case chunk |> String.split("=") do
        [param, ""] -> param
        [param, value] -> "#{param}=#{value}"
      end
    end)
    |> Enum.join("&")
  end

  defp remove_dup_spaces(""), do: ""
  defp remove_dup_spaces("  " <> rest), do: remove_dup_spaces(" " <> rest)
  defp remove_dup_spaces(<< char :: binary-1, rest :: binary>>) do
    char <> remove_dup_spaces(rest)
  end

  defp string_to_sign(request, service, datetime, config) do
    request = hash_sha256(request)

    """
    AWS4-HMAC-SHA256
    #{amz_date(datetime)}
    #{Credentials.generate_credential_scope_v4(service, config, datetime)}
    #{request}
    """
    |> String.rstrip
  end

  defp signed_headers(headers) do
    headers
    |> Enum.map(fn({k, _}) -> String.downcase(k) end)
    |> Enum.sort(&(&1 < &2))
    |> Enum.join(";")
  end

  defp canonical_query_params(nil), do: ""
  defp canonical_query_params(params) do
    params
    |> Enum.sort(fn {k1, _}, {k2, _} -> k1 < k2 end)
    |> Enum.map_join("&", &pair/1)
  end

  defp pair({k, _}) when is_list(k) do
    raise ArgumentError, "encode_query/1 keys cannot be lists, got: #{inspect k}"
  end

  defp pair({_, v}) when is_list(v) do
    raise ArgumentError, "encode_query/1 values cannot be lists, got: #{inspect v}"
  end

  defp pair({k, v}) do
    URI.encode_www_form(Kernel.to_string(k)) <>
    "=" <> aws_encode_www_form(Kernel.to_string(v))
  end

  # is basically the same as URI.encode_www_form
  # but doesn't use %20 instead of "+"
  def aws_encode_www_form(str) when is_binary(str) do
    import Bitwise
    for <<c <- str>>, into: "" do
      case URI.char_unreserved?(c) do
        true  -> <<c>>
        false -> "%" <> hex(bsr(c, 4)) <> hex(band(c, 15))
      end
    end
  end

  defp hex(n) when n <= 9, do: <<n + ?0>>
  defp hex(n), do: <<n + ?A - 10>>

  defp canonical_headers(headers) do
    headers
    |> Enum.map(fn
      {k, v} when is_binary(v) -> {String.downcase(k), String.strip(v)}
      {k, v} -> {String.downcase(k), v}
    end)
    |> Enum.sort(fn {k1, _}, {k2, _} -> k1 < k2 end)
  end

  defp canonical_headers_v2(headers) do
    headers
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "x-amz") end)
    |> canonical_headers
  end

  defp presigned_url_headers(url) do
    uri = URI.parse(url)
    [{"host", uri.authority}]
  end

  defp build_amz_query_params(service, datetime, config, expires) do
    [
      {"X-Amz-Algorithm",     "AWS4-HMAC-SHA256"},
      {"X-Amz-Credential",    Credentials.generate_credential_v4(service, config, datetime)},
      {"X-Amz-Date",          amz_date(datetime)},
      {"X-Amz-Expires",       expires},
      {"X-Amz-SignedHeaders", "host"},
    ] ++
    if config[:security_token] do
      [{"X-Amz-Security-Token", config[:security_token]}]
    else
      []
    end
  end
end
