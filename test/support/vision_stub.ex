defmodule VerifyBarcodes.OpenAI.VisionStub do
  @criteria [
    "Barcode Dimensions",
    "Colour & Contrast",
    "Quiet Zones",
    "Placement Orientation",
    "Symbology",
    "Truncation",
    "Symbol Contrast",
    "Print Quality",
    "Human Readable Interpretation (HRI)",
    "Bar Width Reduction",
    "Substrate & Print Process",
    "Defects"
  ]

  def analyse_image(_base64_image, media_type, _prompt, _opts \\ []) do
    if pid = Application.get_env(:verify_barcodes, :vision_test_pid) do
      send(pid, {:vision_called, media_type})
    end

    if response = Application.get_env(:verify_barcodes, :vision_test_response) do
      case response do
        response when is_binary(response) -> {:ok, response}
        response -> {:ok, Jason.encode!(response)}
      end
    else
      checks =
        Enum.map(@criteria, fn criterion ->
          %{
            "criterion" => criterion,
            "status" => "PASS",
            "finding" => "Stub analysis found no visible issues.",
            "recommendation" => nil
          }
        end)

      response = %{
        "overall_verdict" => "PASS",
        "overall_score" => 98,
        "summary" => "Stub barcode analysis succeeded.",
        "checks" => checks
      }

      {:ok, Jason.encode!(response)}
    end
  end
end
