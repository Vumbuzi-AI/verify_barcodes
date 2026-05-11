defmodule VerifyBarcodes.VerifyGtin do
  @verified_by_gs1_url "https://grp.gs1.org/grp/v3.2/gtins/verified"
  @gs1_kenya_url "https://gs1kenya.org/activate/getbarcode"

  defmodule ReqClient do
    def post(url, options), do: Req.post(url, options)
  end

  def verify(gtin) when is_binary(gtin) do
    case lookup_verified_by_gs1(gtin) do
      {:ok, :not_verified} -> lookup_gs1_kenya(gtin)
      {:ok, product} -> {:ok, product}
      {:error, _reason} -> lookup_gs1_kenya(gtin)
    end
  rescue
    _error ->
      {:ok, :not_verified}
  catch
    _kind, _reason ->
      {:ok, :not_verified}
  end

  defp lookup_verified_by_gs1(gtin) do
    headers = [
      {"Content-Type", "application/json"},
      {"Cache-Control", "no-cache"},
      {"APIKEY", "5c969e5eb17a4704a07c9ad7557190fa"}
    ]

    body = [VerifyBarcodes.Gtin.pad_to_14(gtin)]

    req_options = [
      headers: headers,
      json: body,
      retry: :transient,
      max_retries: 5,
      receive_timeout: 60_000
    ]

    case http_client().post(@verified_by_gs1_url, req_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        case Enum.at(body, 0) do
          nil ->
            {:ok, :not_verified}

          product ->
            product = normalize_verified_by_gs1_product(product, gtin)

            if meaningful_product_data?(product) do
              {:ok, product}
            else
              {:ok, :not_verified}
            end
        end

      {:ok, %Req.Response{status: status}} when status in 400..599 ->
        {:ok, :not_verified}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:ok, :not_verified}
    end
  end

  defp lookup_gs1_kenya(gtin) do
    gtin
    |> gs1_kenya_candidates()
    |> Enum.reduce_while({:ok, :not_verified}, fn candidate, _acc ->
      case lookup_gs1_kenya_candidate(candidate, gtin) do
        {:ok, :not_verified} -> {:cont, {:ok, :not_verified}}
        result -> {:halt, result}
      end
    end)
  end

  defp lookup_gs1_kenya_candidate(candidate, original_gtin) do
    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    req_options = [
      headers: headers,
      json: %{"id" => %{"barcode" => candidate}},
      retry: :transient,
      max_retries: 5,
      receive_timeout: 60_000
    ]

    case http_client().post(@gs1_kenya_url, req_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        case normalize_gs1_kenya_product(body, original_gtin) do
          nil -> {:ok, :not_verified}
          product -> {:ok, product}
        end

      {:ok, %Req.Response{status: status}} when status in 400..599 ->
        {:ok, :not_verified}

      {:error, _reason} ->
        {:ok, :not_verified}

      _ ->
        {:ok, :not_verified}
    end
  end

  defp normalize_verified_by_gs1_product(product, gtin) do
    %{
      gtin: extract_string(product["gtin"]) || gtin,
      brand: extract_value(product["brandName"]),
      name: nil,
      description: extract_value(product["productDescription"]),
      category: extract_string(product["gpcCategoryCode"]),
      net_content: extract_verified_by_gs1_net_content(product["netContent"]),
      country_of_sale: extract_country(product["countryOfSaleCode"]),
      target_market: nil,
      unit_of_measure: nil,
      image_url: extract_value(product["productImageUrl"]),
      licensee: extract_manufacturer(product["gs1Licence"]),
      source_label: "Verified by GS1"
    }
  end

  defp gs1_kenya_candidates(gtin) do
    [strip_single_leading_zero(gtin), gtin]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp strip_single_leading_zero("0" <> rest) when byte_size(rest) == 13, do: rest
  defp strip_single_leading_zero(_gtin), do: nil

  defp normalize_gs1_kenya_product(product, gtin) do
    normalized = %{
      gtin: gtin,
      brand: nil,
      name: extract_string(product["name"]),
      description: extract_string(product["description"]),
      category: extract_string(product["classify"]),
      net_content:
        extract_gs1_kenya_net_content(product["weight"], product["uom"], product["package"]),
      country_of_sale: nil,
      target_market: target_market_label(product["target"]),
      unit_of_measure: uom_label(product["uom"]),
      image_url: extract_image_url(product["image"]),
      licensee: extract_string(product["company"]),
      source_label: "GS1 Kenya"
    }

    if normalized
       |> Map.drop([:gtin, :source_label])
       |> Enum.any?(fn {_key, value} -> present?(value) end) do
      normalized
    end
  end

  defp extract_value([first | _]) when is_map(first), do: extract_string(Map.get(first, "value"))
  defp extract_value(_), do: nil

  defp extract_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp extract_string(_), do: nil

  defp extract_verified_by_gs1_net_content([first | _]) when is_map(first) do
    [Map.get(first, "value"), Map.get(first, "unitCode")]
    |> Enum.map(&extract_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> extract_string()
  end

  defp extract_verified_by_gs1_net_content(_), do: nil

  defp extract_gs1_kenya_net_content(weight, uom, package) do
    [extract_string(weight), uom_label(uom), extract_string(package)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> extract_string()
  end

  defp extract_country([first | _]) when is_map(first) do
    [Map.get(first, "alpha3"), Map.get(first, "alpha2"), Map.get(first, "numeric")]
    |> Enum.map(&extract_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [alpha3, alpha2 | _] -> "#{alpha3} (#{alpha2})"
      [country | _] -> country
      _ -> nil
    end
  end

  defp extract_country(_), do: nil

  defp extract_manufacturer(%{"licenseeName" => name}), do: extract_string(name)
  defp extract_manufacturer(_), do: nil

  defp extract_image_url(value) do
    value
    |> extract_string()
    |> case do
      "https://gs1kenya.org/uploads/" -> nil
      other -> other
    end
  end

  defp target_market_label(value) do
    case extract_string(value) do
      "001" -> "Global"
      other -> other
    end
  end

  defp uom_label(value) do
    case value |> extract_string() |> maybe_upcase() do
      "H87" -> "Piece"
      "U2" -> "Tablet"
      other -> other
    end
  end

  defp maybe_upcase(nil), do: nil
  defp maybe_upcase(value), do: String.upcase(value)

  defp present?(value), do: value not in [nil, "", []]

  defp meaningful_product_data?(product) do
    product
    |> Map.drop([:gtin, :source_label])
    |> Enum.any?(fn {_key, value} -> present?(value) end)
  end

  defp http_client do
    Application.get_env(:verify_barcodes, :gtin_http_client, ReqClient)
  end
end
