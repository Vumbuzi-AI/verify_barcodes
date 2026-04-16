defmodule VerifyBarcodesWeb.BarcodeLive.IndexTest do
  use VerifyBarcodesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous_client = Application.get_env(:verify_barcodes, :vision_client)
    previous_test_pid = Application.get_env(:verify_barcodes, :vision_test_pid)
    previous_test_response = Application.get_env(:verify_barcodes, :vision_test_response)

    Application.put_env(:verify_barcodes, :vision_client, VerifyBarcodes.OpenAI.VisionStub)
    Application.put_env(:verify_barcodes, :vision_test_pid, self())

    on_exit(fn ->
      restore_env(:vision_client, previous_client)
      restore_env(:vision_test_pid, previous_test_pid)
      restore_env(:vision_test_response, previous_test_response)
    end)

    :ok
  end

  test "submitting a completed upload starts analysis and renders the result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    upload =
      file_input(view, "#upload-form", :barcode_image, [
        %{
          name: "barcode.png",
          content: "fake image bytes",
          type: "image/png"
        }
      ])

    assert render_upload(upload, "barcode.png") =~ "100%"
    assert render_submit(form(view, "#upload-form", %{}))

    assert_receive {:vision_called, "image/png"}

    html = render(view)
    assert html =~ "Overall Verdict"
    assert html =~ "PASS"
    assert html =~ "Stub barcode analysis succeeded."
  end

  test "wordy cannot determine findings are compressed before rendering", %{conn: conn} do
    Application.put_env(:verify_barcodes, :vision_test_response, verbose_cannot_determine_response())

    {:ok, view, _html} = live(conn, ~p"/")

    upload =
      file_input(view, "#upload-form", :barcode_image, [
        %{
          name: "barcode.png",
          content: "fake image bytes",
          type: "image/png"
        }
      ])

    assert render_upload(upload, "barcode.png") =~ "100%"
    assert render_submit(form(view, "#upload-form", %{}))

    assert_receive {:vision_called, "image/png"}

    html = render(view)

    assert html =~ "No scale reference is visible, so exact dimensions cannot be verified."
    assert html =~ "Bar edges look clean, but print compensation cannot be confirmed without print specifications."
    assert html =~ "Surface detail is too limited to identify the substrate or print process."

    refute html =~
             "there is no production specification or comparative reference in the image to determine whether bar width reduction or ink spread compensation was applied"

    refute html =~
             "The image is tightly cropped around the symbol and does not show enough surface detail to identify the substrate or printing process reliably."
  end

  defp verbose_cannot_determine_response do
    checks = [
      %{
        "criterion" => "Barcode Dimensions",
        "status" => "CANNOT_DETERMINE",
        "finding" => "Exact dimensions cannot be determined because there is no visible scale reference or dimensional baseline in the image.",
        "recommendation" => "Verify dimensions with a ruler or digital tool."
      },
      %{
        "criterion" => "Colour & Contrast",
        "status" => "PASS",
        "finding" => "Dark bars are clearly visible on a light background.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Quiet Zones",
        "status" => "PASS",
        "finding" => "Quiet zones appear present on both sides of the symbol.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Placement Orientation",
        "status" => "PASS",
        "finding" => "The symbol appears upright and unobstructed.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Symbology",
        "status" => "PASS",
        "finding" => "The symbol format appears appropriate for the presented use case.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Truncation",
        "status" => "PASS",
        "finding" => "The visible bar height does not appear unusually short.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Symbol Contrast",
        "status" => "PASS",
        "finding" => "The symbol shows strong visible contrast.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Print Quality",
        "status" => "PASS",
        "finding" => "The visible print quality appears consistent.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Human Readable Interpretation (HRI)",
        "status" => "PASS",
        "finding" => "Human-readable text appears below the symbol.",
        "recommendation" => nil
      },
      %{
        "criterion" => "Bar Width Reduction",
        "status" => "CANNOT_DETERMINE",
        "finding" => "The bars appear fairly clean, but there is no production specification or comparative reference in the image to determine whether bar width reduction or ink spread compensation was applied.",
        "recommendation" => "Verify with printing specifications."
      },
      %{
        "criterion" => "Substrate & Print Process",
        "status" => "CANNOT_DETERMINE",
        "finding" => "The image is tightly cropped around the symbol and does not show enough surface detail to identify the substrate or printing process reliably.",
        "recommendation" => "Ensure suitable substrate and print process."
      },
      %{
        "criterion" => "Defects",
        "status" => "PASS",
        "finding" => "No obvious smudges or voids are visible.",
        "recommendation" => nil
      }
    ]

    %{
      "overall_verdict" => "WARNING",
      "overall_score" => 78,
      "summary" => "Some checks pass, but a few criteria cannot be confirmed from the image alone.",
      "checks" => checks
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:verify_barcodes, key)
  defp restore_env(key, value), do: Application.put_env(:verify_barcodes, key, value)
end
