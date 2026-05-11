defmodule VerifyBarcodes.VerifyGtinTest do
  use ExUnit.Case, async: false

  @verified_by_gs1_url "https://grp.gs1.org/grp/v3.2/gtins/verified"
  @gs1_kenya_url "https://gs1kenya.org/activate/getbarcode"

  setup do
    previous_client = Application.get_env(:verify_barcodes, :gtin_http_client)
    previous_test_pid = Application.get_env(:verify_barcodes, :gtin_http_test_pid)
    previous_responses = Application.get_env(:verify_barcodes, :gtin_http_test_responses)

    Application.put_env(:verify_barcodes, :gtin_http_client, VerifyBarcodes.GtinHttpClientStub)
    Application.put_env(:verify_barcodes, :gtin_http_test_pid, self())

    on_exit(fn ->
      restore_env(:gtin_http_client, previous_client)
      restore_env(:gtin_http_test_pid, previous_test_pid)
      restore_env(:gtin_http_test_responses, previous_responses)
    end)

    :ok
  end

  test "returns normalized Verified by GS1 data without using the fallback endpoint" do
    Application.put_env(
      :verify_barcodes,
      :gtin_http_test_responses,
      %{
        @verified_by_gs1_url =>
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{
                 "gtin" => "09506000134352",
                 "brandName" => [%{"value" => "Acme Foods"}],
                 "productDescription" => [%{"value" => "Roasted ground coffee"}],
                 "gpcCategoryCode" => "10000045",
                 "netContent" => [%{"value" => "500", "unitCode" => "GRM"}],
                 "countryOfSaleCode" => [%{"alpha3" => "KEN", "alpha2" => "KE"}],
                 "productImageUrl" => [%{"value" => "https://example.com/product.png"}],
                 "gs1Licence" => %{"licenseeName" => "Acme Foods Ltd"}
               }
             ]
           }}
      }
    )

    assert {:ok, product} = VerifyBarcodes.VerifyGtin.verify("9506000134352")

    assert product.source_label == "Verified by GS1"
    assert product.gtin == "09506000134352"
    assert product.brand == "Acme Foods"
    assert product.description == "Roasted ground coffee"
    assert product.net_content == "500 GRM"
    assert product.country_of_sale == "KEN (KE)"
    assert product.licensee == "Acme Foods Ltd"

    assert_received {:gtin_http_called, @verified_by_gs1_url, verified_options}
    assert verified_options[:json] == ["09506000134352"]
    refute_received {:gtin_http_called, @gs1_kenya_url, _options}
  end

  test "falls back to GS1 Kenya and maps target 001 and H87 for the UI" do
    Application.put_env(
      :verify_barcodes,
      :gtin_http_test_responses,
      fn
        @verified_by_gs1_url, _options ->
          {:ok, %Req.Response{status: 200, body: []}}

        @gs1_kenya_url, options ->
          assert options[:json] == %{"id" => %{"barcode" => "6161101890151"}}

          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "weight" => "1",
               "uom" => "H87",
               "target" => "001",
               "package" => nil,
               "name" => "Cosy",
               "image" => "https://gs1kenya.org/uploads/",
               "description" => "Cosy serviette 10 extra",
               "company" => "KIM-FAY EAST AFRICA LIMITED",
               "classify" => "Beauty/Personal Care/Hygiene Variety Packs"
             }
           }}
      end
    )

    assert {:ok, product} = VerifyBarcodes.VerifyGtin.verify("6161101890151")

    assert product.source_label == "GS1 Kenya"
    assert product.gtin == "6161101890151"
    assert product.name == "Cosy"
    assert product.description == "Cosy serviette 10 extra"
    assert product.category == "Beauty/Personal Care/Hygiene Variety Packs"
    assert product.net_content == "1 Piece"
    assert product.target_market == "Global"
    assert product.unit_of_measure == "Piece"
    assert product.image_url == nil
    assert product.licensee == "KIM-FAY EAST AFRICA LIMITED"

    assert_received {:gtin_http_called, @verified_by_gs1_url, _verified_options}
    assert_received {:gtin_http_called, @gs1_kenya_url, _kenya_options}
  end

  test "falls back to GS1 Kenya when Verified by GS1 only returns the GTIN" do
    Application.put_env(
      :verify_barcodes,
      :gtin_http_test_responses,
      fn
        @verified_by_gs1_url, _options ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{
                 "gtin" => "06161101890151",
                 "brandName" => [],
                 "productDescription" => [],
                 "gpcCategoryCode" => nil,
                 "netContent" => [],
                 "countryOfSaleCode" => [],
                 "productImageUrl" => [],
                 "gs1Licence" => %{}
               }
             ]
           }}

        @gs1_kenya_url, options ->
          assert options[:json] == %{"id" => %{"barcode" => "6161101890151"}}

          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "weight" => "1",
               "uom" => "H87",
               "target" => "001",
               "package" => nil,
               "name" => "Cosy",
               "image" => "https://gs1kenya.org/uploads/",
               "description" => " Cosy serviette 10 extra",
               "company" => "KIM-FAY EAST AFRICA LIMITED",
               "classify" => "Beauty/Personal Care/Hygiene Variety Packs"
             }
           }}
      end
    )

    assert {:ok, product} = VerifyBarcodes.VerifyGtin.verify("06161101890151")

    assert product.source_label == "GS1 Kenya"
    assert product.gtin == "06161101890151"
    assert product.name == "Cosy"
    assert product.description == "Cosy serviette 10 extra"
    assert product.net_content == "1 Piece"
    assert product.target_market == "Global"
    assert product.unit_of_measure == "Piece"
    assert product.licensee == "KIM-FAY EAST AFRICA LIMITED"
  end

  test "maps GS1 Kenya u2 to Tablet" do
    Application.put_env(
      :verify_barcodes,
      :gtin_http_test_responses,
      fn
        @verified_by_gs1_url, _options ->
          {:error, :timeout}

        @gs1_kenya_url, _options ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "weight" => "30",
               "uom" => "u2",
               "target" => "404",
               "package" => nil,
               "name" => "Pain Relief",
               "company" => "Example Pharma"
             }
           }}
      end
    )

    assert {:ok, product} = VerifyBarcodes.VerifyGtin.verify("1234567890128")

    assert product.net_content == "30 Tablet"
    assert product.unit_of_measure == "Tablet"
    assert product.target_market == "404"
  end

  defp restore_env(key, nil), do: Application.delete_env(:verify_barcodes, key)
  defp restore_env(key, value), do: Application.put_env(:verify_barcodes, key, value)
end
