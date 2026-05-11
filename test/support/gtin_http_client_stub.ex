defmodule VerifyBarcodes.GtinHttpClientStub do
  def post(url, options) do
    if pid = Application.get_env(:verify_barcodes, :gtin_http_test_pid) do
      send(pid, {:gtin_http_called, url, options})
    end

    case Application.get_env(:verify_barcodes, :gtin_http_test_responses, %{}) do
      responder when is_function(responder, 2) ->
        responder.(url, options)

      responses when is_map(responses) ->
        Map.get(responses, url, {:error, :missing_stub_response})
    end
  end
end
