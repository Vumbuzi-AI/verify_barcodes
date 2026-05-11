defmodule VerifyBarcodes.VerifyGtin do
  require Logger

  @verified_by_gs1_url "https://grp.gs1.org/grp/v3.2/gtins/verified"
  @default_gs1_kenya_url "https://gs1kenya.org/activate/getbarcode"

  defmodule ReqClient do
    def post(url, options), do: Req.post(url, options)
  end

  def verify(gtin) when is_binary(gtin) do
    Logger.info("Starting GTIN registry lookup for #{gtin}")

    case lookup_verified_by_gs1(gtin) do
      {:ok, :not_verified} ->
        Logger.info(
          "Verified by GS1 did not return usable product data for #{gtin}; trying GS1 Kenya"
        )

        lookup_gs1_kenya(gtin)

      {:ok, product} ->
        Logger.info(
          "GTIN #{gtin} matched product data from #{product[:source_label] || "registry"}"
        )

        {:ok, product}

      {:error, reason} ->
        Logger.warning(
          "Verified by GS1 lookup failed for #{gtin}: #{inspect(reason)}; trying GS1 Kenya"
        )

        lookup_gs1_kenya(gtin)
    end
  rescue
    error ->
      Logger.error("GTIN lookup crashed for #{gtin}: #{Exception.message(error)}")
      {:ok, :not_verified}
  catch
    kind, reason ->
      Logger.error("GTIN lookup threw #{inspect(kind)} for #{gtin}: #{inspect(reason)}")
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

    Logger.debug("Posting GTIN #{gtin} to Verified by GS1")

    case http_client().post(@verified_by_gs1_url, req_options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        Logger.debug("Verified by GS1 returned 200 for #{gtin} with #{length(body)} result(s)")

        case Enum.at(body, 0) do
          nil ->
            Logger.info("Verified by GS1 returned no records for #{gtin}")
            {:ok, :not_verified}

          product ->
            product = normalize_verified_by_gs1_product(product, gtin)

            if meaningful_product_data?(product) do
              Logger.info("Verified by GS1 returned usable product data for #{gtin}")
              {:ok, product}
            else
              Logger.info("Verified by GS1 returned only sparse product data for #{gtin}")
              {:ok, :not_verified}
            end
        end

      {:ok, %Req.Response{status: status}} when status in 400..599 ->
        Logger.warning("Verified by GS1 returned HTTP #{status} for #{gtin}")
        {:ok, :not_verified}

      {:error, reason} ->
        Logger.warning("Verified by GS1 request errored for #{gtin}: #{inspect(reason)}")
        {:error, reason}

      _ ->
        Logger.warning("Verified by GS1 returned an unexpected response for #{gtin}")
        {:ok, :not_verified}
    end
  end

  defp lookup_gs1_kenya(gtin) do
    candidates = gs1_kenya_candidates(gtin)

    Logger.info(
      "Trying GS1 Kenya lookup for #{gtin} with candidate(s): #{Enum.join(candidates, ", ")}"
    )

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

    Logger.debug(
      "Posting barcode candidate #{candidate} to GS1 Kenya for original GTIN #{original_gtin}"
    )

    case http_client().post(gs1_kenya_url(), req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        Logger.debug("GS1 Kenya returned 200 for candidate #{candidate}")

        case decode_gs1_kenya_body(body) do
          {:ok, decoded_body} ->
            Logger.debug(
              "GS1 Kenya decoded response keys for candidate #{candidate}: #{inspect(Map.keys(decoded_body))}"
            )

            case normalize_gs1_kenya_product(decoded_body, original_gtin) do
              nil ->
                Logger.info(
                  "GS1 Kenya returned no usable product data for candidate #{candidate}"
                )

                {:ok, :not_verified}

              product ->
                Logger.info(
                  "GS1 Kenya returned product data for original GTIN #{original_gtin} using candidate #{candidate}"
                )

                {:ok, product}
            end

          {:error, reason} ->
            Logger.warning(
              "GS1 Kenya returned a 200 response but the body could not be decoded for candidate #{candidate}: #{inspect(reason)}"
            )

            {:ok, :not_verified}
        end

      {:ok, %Req.Response{status: status}} when status in 400..599 ->
        Logger.warning("GS1 Kenya returned HTTP #{status} for candidate #{candidate}")
        {:ok, :not_verified}

      {:error, _reason} ->
        Logger.warning("GS1 Kenya request errored for candidate #{candidate}")
        {:ok, :not_verified}

      _ ->
        Logger.warning("GS1 Kenya returned an unexpected response for candidate #{candidate}")
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

  defp decode_gs1_kenya_body(body) when is_map(body), do: {:ok, body}

  defp decode_gs1_kenya_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, decoded} -> {:error, {:unexpected_json_shape, decoded}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_gs1_kenya_body(body), do: {:error, {:unexpected_body_type, body}}

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

  defp gs1_kenya_url do
    Application.get_env(:verify_barcodes, :gs1_kenya_getbarcode_url, @default_gs1_kenya_url)
  end
end
