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
    {:ok, view, initial_html} = live(conn, ~p"/")

    assert initial_html =~ "Check if your barcode is market-ready"
    assert initial_html =~ "Choose the pack shape"
    assert initial_html =~ "Upload product barcode"
    assert initial_html =~ "Flat / straight"
    assert initial_html =~ "Selected"

    upload =
      file_input(view, "#upload-form", :barcode_image, [
        %{
          name: "barcode.png",
          content: "fake image bytes",
          type: "image/png"
        }
      ])

    assert render_upload(upload, "barcode.png") =~ "100%"
    upload_html = render(view)
    assert upload_html =~ "Ready to check"
    assert upload_html =~ "Choose different image"
    refute upload_html =~ "GS1 Kenya Barcode Verifier"

    assert render_submit(form(view, "#upload-form", %{"surface_type" => "straight"}))

    assert_receive {:vision_called, "image/png", prompt}
    assert prompt =~ "Surface context: the barcode is on a straight/flat surface."

    html = wait_for_render(view, "Summary")
    assert html =~ "Summary"
    assert html =~ "Passed checks"
    assert html =~ "Checks"
    assert html =~ "Pass"
    assert html =~ "Placement"
    assert html =~ "bg-emerald-600"
  end

  test "wordy cannot determine findings are compressed before rendering", %{conn: conn} do
    Application.put_env(
      :verify_barcodes,
      :vision_test_response,
      verbose_cannot_determine_response()
    )

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
    assert render_submit(form(view, "#upload-form", %{"surface_type" => "unknown"}))

    assert_receive {:vision_called, "image/png", _prompt}

    html = wait_for_render(view, "Checks")

    refute html =~ "Barcode Dimensions"
    refute html =~ "No scale reference is visible, so exact dimensions cannot be verified."
    refute html =~ "Surface detail is too limited to identify the substrate or print process."
    refute html =~ "Cannot determine"
    refute html =~ "Could not determine"
    refute html =~ "Spread"
    refute html =~ "Surface"
    refute html =~ "CANNOT_DETERMINE"
    assert position_of(html, "Contrast") < position_of(html, "Defects")
    assert html =~ "Defects"

    refute html =~
             "there is no production specification or comparative reference in the image to determine whether bar width reduction or ink spread compensation was applied"

    refute html =~
             "The image is tightly cropped around the symbol and does not show enough surface detail to identify the substrate or printing process reliably."
  end

  test "verified GTIN renders registry attributes with missing fields first", %{conn: conn} do
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
    assert render_submit(form(view, "#upload-form", %{"surface_type" => "unknown"}))
    assert_receive {:vision_called, "image/png", _prompt}
    assert wait_for_render(view, "Summary") =~ "Summary"

    send(
      view.pid,
      {:gtin_verify_complete,
       {:verified, "09506000134352",
        %{
          gtin: "09506000134352",
          brand: "Acme Foods",
          name: nil,
          description: "Roasted ground coffee",
          category: nil,
          net_content: "500 GRM",
          country_of_sale: nil,
          target_market: nil,
          unit_of_measure: nil,
          image_url: nil,
          licensee: "Acme Foods Ltd",
          source_label: "Verified by GS1"
        }}}
    )

    html = render(view)

    assert html =~ "Registry attributes are shown here, with missing fields first."
    assert html =~ "4/7 available"
    assert html =~ "Company"
    assert html =~ "Acme Foods Ltd"

    assert position_of(html, "Product category") < position_of(html, "Product name")
    assert position_of(html, "Product category") < position_of(html, "Product description")
    assert position_of(html, "Market") < position_of(html, "Net content")
    assert position_of(html, "Unit of measure") < position_of(html, "Product name")
  end

  test "wrapped JSON responses are recovered before rendering", %{conn: conn} do
    Application.put_env(
      :verify_barcodes,
      :vision_test_response,
      "Here is the structured result:\n```json\n#{Jason.encode!(default_response())}\n```"
    )

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
    assert render_submit(form(view, "#upload-form", %{"surface_type" => "straight"}))

    html = wait_for_render(view, "Summary")

    assert html =~ "Stub analysis found no visible issues."
    assert html =~ "Checks"
  end

  defp verbose_cannot_determine_response do
    checks = [
      %{
        "criterion" => "Barcode Dimensions",
        "status" => "CANNOT_DETERMINE",
        "finding" =>
          "Exact dimensions cannot be determined because there is no visible scale reference or dimensional baseline in the image.",
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
        "finding" =>
          "The bars appear fairly clean, but there is no production specification or comparative reference in the image to determine whether bar width reduction or ink spread compensation was applied.",
        "recommendation" => "Verify with printing specifications."
      },
      %{
        "criterion" => "Substrate & Print Process",
        "status" => "CANNOT_DETERMINE",
        "finding" =>
          "The image is tightly cropped around the symbol and does not show enough surface detail to identify the substrate or printing process reliably.",
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
      "summary" =>
        "Some checks pass, but a few criteria cannot be confirmed from the image alone.",
      "checks" => checks
    }
  end

  defp default_response do
    %{
      "overall_verdict" => "PASS",
      "overall_score" => 98,
      "summary" => "Stub barcode analysis succeeded.",
      "gtin" => "",
      "checks" =>
        Enum.map(criteria(), fn criterion ->
          %{
            "criterion" => criterion,
            "status" => "PASS",
            "finding" => "Stub analysis found no visible issues.",
            "recommendation" => ""
          }
        end)
    }
  end

  defp criteria do
    [
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
  end

  defp position_of(html, snippet) do
    html
    |> :binary.match(snippet)
    |> elem(0)
  end

  defp wait_for_render(view, snippet, attempts \\ 50)

  defp wait_for_render(view, snippet, attempts) when attempts > 0 do
    html = render(view)

    if html =~ snippet do
      html
    else
      Process.sleep(20)
      wait_for_render(view, snippet, attempts - 1)
    end
  end

  defp wait_for_render(view, _snippet, 0), do: render(view)

  defp restore_env(key, nil), do: Application.delete_env(:verify_barcodes, key)
  defp restore_env(key, value), do: Application.put_env(:verify_barcodes, key, value)
end
