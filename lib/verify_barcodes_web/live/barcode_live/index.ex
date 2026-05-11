defmodule VerifyBarcodesWeb.BarcodeLive.Index do
  use VerifyBarcodesWeb, :live_view

  @user_prompt "Analyse the uploaded barcode image and return your structured verdict as JSON only."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "GS1 Kenya Barcode Verifier")
     |> assign(
       :page_description,
       "Upload a barcode image and get an AI-assisted GS1-style verification summary with a score, findings, and recommendations."
     )
     |> assign(:page_url, url(~p"/"))
     |> assign(:page_image, url(~p"/images/gs1.png"))
     |> assign(:page_type, "website")
     |> assign(:status, :idle)
     |> assign(:result, nil)
     |> assign(:error_message, nil)
     |> assign(:preview_url, nil)
     |> assign(:gtin_status, :none)
     |> assign(:detected_gtin, nil)
     |> assign(:product, nil)
     |> assign(:surface_type, "straight")
     |> allow_upload(:barcode_image,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 5_000_000
     )}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :surface_type, extract_surface_type(params))}
  end

  def handle_event("analyse", params, socket) do
    surface_type = extract_surface_type(params)

    case uploaded_entries(socket, :barcode_image) do
      {[], [_ | _]} ->
        {:noreply,
         socket
         |> assign(:surface_type, surface_type)
         |> assign(:error_message, "Upload is still in progress. Please wait.")}

      {[], []} ->
        {:noreply,
         socket
         |> assign(:surface_type, surface_type)
         |> assign(:error_message, "Please select a file first.")}

      {[_ | _], _} ->
        uploads =
          consume_uploaded_entries(socket, :barcode_image, fn %{path: path}, entry ->
            binary = File.read!(path)
            {:ok, %{binary: binary, media_type: entry.client_type}}
          end)

        case uploads do
          [%{binary: binary, media_type: media_type}] ->
            base64 = Base.encode64(binary)
            parent = self()
            vision_module = vision_module()
            prompt = analysis_prompt(surface_type)

            Task.start(fn ->
              result = vision_module.analyse_image(base64, media_type, prompt)

              send(parent, {:analysis_complete, result})
            end)

            {:noreply,
             socket
             |> assign(:status, :analysing)
             |> assign(:surface_type, surface_type)
             |> assign(:preview_url, "data:#{media_type};base64,#{base64}")
             |> assign(:error_message, nil)}

          _ ->
            {:noreply,
             socket
             |> assign(:surface_type, surface_type)
             |> assign(:error_message, "Please select a file first.")}
        end
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:status, :idle)
     |> assign(:result, nil)
     |> assign(:preview_url, nil)
     |> assign(:error_message, nil)
     |> assign(:gtin_status, :none)
     |> assign(:detected_gtin, nil)
     |> assign(:product, nil)
     |> assign(:surface_type, "straight")}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :barcode_image, ref)}
  end

  @impl true
  def handle_info({:analysis_complete, {:ok, raw_text}}, socket) do
    case parse_ai_response(raw_text) do
      {:ok, result} ->
        {:noreply,
         socket
         |> assign(:status, :complete)
         |> assign(:result, result)
         |> start_gtin_verify(result)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> assign(:error_message, message)}
    end
  end

  def handle_info({:gtin_verify_complete, {:verified, gtin, product}}, socket) do
    {:noreply,
     socket
     |> assign(:gtin_status, :verified)
     |> assign(:detected_gtin, gtin)
     |> assign(:product, product)}
  end

  def handle_info({:gtin_verify_complete, {:not_verified, gtin}}, socket) do
    {:noreply,
     socket
     |> assign(:gtin_status, :not_verified)
     |> assign(:detected_gtin, gtin)}
  end

  def handle_info({:gtin_verify_complete, {:invalid, gtin, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(:gtin_status, :invalid)
     |> assign(:detected_gtin, gtin)}
  end

  def handle_info({:analysis_complete, {:error, reason}}, socket) do
    message =
      case reason do
        :missing_openai_api_key -> "OpenAI API key is not configured."
        :empty_response -> "The AI returned an empty response. Please try again."
        :api_error -> "The AI service returned an error. Please try again."
        _ -> "The analysis failed. Please try again."
      end

    {:noreply,
     socket
     |> assign(:status, :error)
     |> assign(:error_message, message)}
  end

  defp start_gtin_verify(socket, %{"gtin" => gtin_raw}) do
    case sanitize_gtin(gtin_raw) do
      nil ->
        assign(socket, :gtin_status, :no_gtin)

      digits ->
        parent = self()

        Task.start(fn ->
          message =
            case VerifyBarcodes.Gtin.validate(digits) do
              {:ok, gtin} ->
                padded = VerifyBarcodes.Gtin.pad_to_14(gtin)

                case VerifyBarcodes.VerifyGtin.verify(padded) do
                  {:ok, :not_verified} ->
                    {:gtin_verify_complete, {:not_verified, gtin}}

                  {:ok, body} when is_list(body) and body != [] ->
                    {:gtin_verify_complete, {:verified, gtin, extract_product(body)}}

                  _ ->
                    {:gtin_verify_complete, {:not_verified, gtin}}
                end

              {:error, reason} ->
                {:gtin_verify_complete, {:invalid, digits, reason}}
            end

          send(parent, message)
        end)

        assign(socket, :gtin_status, :verifying)
    end
  end

  defp start_gtin_verify(socket, _result), do: assign(socket, :gtin_status, :no_gtin)

  defp sanitize_gtin(value) when is_binary(value) do
    case String.replace(value, ~r/\D/, "") do
      "" -> nil
      digits -> digits
    end
  end

  defp sanitize_gtin(_), do: nil

  defp extract_surface_type(%{"surface_type" => surface_type})
       when surface_type in ["straight", "curved", "unknown"],
       do: surface_type

  defp extract_surface_type(_), do: "straight"

  defp analysis_prompt(surface_type) do
    surface_context =
      case surface_type do
        "straight" ->
          "Surface context: the barcode is on a straight/flat surface."

        "curved" ->
          "Surface context: the barcode is on a curved surface."

        _ ->
          "Surface context: the user did not confirm whether the surface is straight or curved."
      end

    Enum.join([@user_prompt, surface_context], " ")
  end

  defp extract_product(body) do
    first = Enum.at(body, 0) || %{}

    %{
      gtin: extract_string(first["gtin"]),
      brand: extract_value(first["brandName"]),
      description: extract_value(first["productDescription"]),
      category: extract_string(first["gpcCategoryCode"]),
      net_content: extract_net_content(first["netContent"]),
      country_of_sale: extract_country(first["countryOfSaleCode"]),
      image_url: extract_value(first["productImageUrl"]),
      licensee: extract_manufacturer(first["gs1Licence"])
    }
  end

  defp extract_value([first | _]) when is_map(first), do: Map.get(first, "value")
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

  defp extract_net_content([first | _]) when is_map(first) do
    [Map.get(first, "value"), Map.get(first, "unitCode")]
    |> Enum.filter(&(not blank_value?(&1)))
    |> Enum.join(" ")
    |> extract_string()
  end

  defp extract_net_content(_), do: nil

  defp extract_country([first | _]) when is_map(first) do
    [Map.get(first, "alpha3"), Map.get(first, "alpha2"), Map.get(first, "numeric")]
    |> Enum.filter(&(not blank_value?(&1)))
    |> case do
      [alpha3, alpha2 | _] -> "#{alpha3} (#{alpha2})"
      [country | _] -> country
      _ -> nil
    end
  end

  defp extract_country(_), do: nil

  defp extract_manufacturer(%{"licenseeName" => name}) when is_binary(name) and name != "",
    do: name

  defp extract_manufacturer(_), do: nil

  defp parse_ai_response(raw_text) do
    raw_text
    |> String.trim()
    |> strip_markdown_fences()
    |> Jason.decode()
    |> case do
      {:ok,
       %{"overall_verdict" => _, "overall_score" => _, "summary" => _, "checks" => checks} =
           result}
      when is_list(checks) ->
        {:ok, normalize_result(result)}

      {:ok, _unexpected} ->
        {:error, "Unexpected response structure from AI."}

      {:error, _} ->
        {:error, "The AI returned a non-JSON response."}
    end
  end

  defp strip_markdown_fences(text) do
    text
    |> String.replace(~r/^```(?:json)?\s*/i, "")
    |> String.replace(~r/\s*```$/, "")
    |> String.trim()
  end

  defp normalize_result(%{"checks" => checks} = result) do
    Map.put(result, "checks", Enum.map(checks, &normalize_check/1))
  end

  defp normalize_check(%{"criterion" => _criterion, "status" => "CANNOT_DETERMINE"} = check) do
    Map.put(check, "finding", concise_cannot_determine_finding(check))
  end

  defp normalize_check(check), do: check

  defp concise_cannot_determine_finding(%{
         "criterion" => "Barcode Dimensions",
         "finding" => finding
       }) do
    if mentions_any?(finding, ["scale", "reference", "magnification", "x-dimension", "dimension"]) do
      "No scale reference is visible, so exact dimensions cannot be verified."
    else
      "Exact dimensions cannot be verified from this image alone."
    end
  end

  defp concise_cannot_determine_finding(%{
         "criterion" => "Bar Width Reduction",
         "finding" => finding
       }) do
    if mentions_any?(finding, ["clean", "edge", "bar"]) do
      "Bar edges look clean, but print compensation cannot be confirmed without print specifications."
    else
      "Print compensation cannot be confirmed from the visible bar detail alone."
    end
  end

  defp concise_cannot_determine_finding(%{
         "criterion" => "Substrate & Print Process",
         "finding" => finding
       }) do
    if mentions_any?(finding, ["surface", "substrate", "material", "print process", "cropped"]) do
      "Surface detail is too limited to identify the substrate or print process."
    else
      "The substrate and print process cannot be identified from this image alone."
    end
  end

  defp concise_cannot_determine_finding(%{"finding" => finding}) do
    finding
    |> squash_whitespace()
    |> first_sentence()
    |> limit_words(18)
  end

  defp mentions_any?(text, fragments) when is_binary(text) do
    downcased = String.downcase(text)
    Enum.any?(fragments, &String.contains?(downcased, &1))
  end

  defp mentions_any?(_, _), do: false

  defp squash_whitespace(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp squash_whitespace(_), do: ""

  defp first_sentence(text) do
    case Regex.run(~r/^.*?[.!?](?=\s|$)/, text) do
      [sentence] -> String.trim(sentence)
      _ -> text
    end
  end

  defp limit_words(text, max_words) do
    words = String.split(text)

    if length(words) <= max_words do
      text
    else
      words
      |> Enum.take(max_words)
      |> Enum.join(" ")
      |> Kernel.<>("...")
    end
  end

  def error_to_string(:too_large), do: "Image is larger than 5MB."
  def error_to_string(:too_many_files), do: "Only one image is allowed."
  def error_to_string(:not_accepted), do: "Unsupported file type. Use JPG, PNG, or WebP."
  def error_to_string(err), do: "Upload error: #{inspect(err)}"

  def verdict_class("PASS"), do: "border-emerald-200 bg-emerald-50 text-emerald-950"
  def verdict_class("FAIL"), do: "border-gs1-orange/25 bg-gs1-orange-soft text-gs1-ink"
  def verdict_class("WARNING"), do: "border-gs1-orange/25 bg-gs1-orange-soft text-gs1-ink"
  def verdict_class(_), do: "border-gs1-blue/15 bg-white text-gs1-ink"

  def status_icon("PASS"), do: "✅"
  def status_icon("FAIL"), do: "❌"
  def status_icon("WARNING"), do: "⚠️"
  def status_icon("CANNOT_DETERMINE"), do: "❓"
  def status_icon(_), do: "❓"

  def status_border("PASS"), do: "border-emerald-200 bg-emerald-50"
  def status_border("FAIL"), do: "border-gs1-orange/25 bg-gs1-orange-soft/60"
  def status_border("WARNING"), do: "border-gs1-orange/25 bg-gs1-orange-soft/60"
  def status_border(_), do: "border-slate-200 bg-white"

  def status_badge("PASS"), do: "bg-emerald-600 text-white"
  def status_badge("FAIL"), do: "bg-gs1-orange text-white"
  def status_badge("WARNING"), do: "bg-gs1-orange text-white"
  def status_badge("CANNOT_DETERMINE"), do: "bg-slate-100 text-slate-600"
  def status_badge(_), do: "bg-slate-100 text-slate-600"

  defp count_status(checks, status) do
    Enum.count(checks || [], &(&1["status"] == status))
  end

  defp short_criterion("Colour & Contrast"), do: "Contrast"
  defp short_criterion("Quiet Zones"), do: "Margins"
  defp short_criterion("Placement Orientation"), do: "Placement"
  defp short_criterion("Symbology"), do: "Format"
  defp short_criterion("Truncation"), do: "Height"
  defp short_criterion("Symbol Contrast"), do: "Clarity"
  defp short_criterion("Print Quality"), do: "Print"
  defp short_criterion("Human Readable Interpretation (HRI)"), do: "Digits"
  defp short_criterion("Bar Width Reduction"), do: "Spread"
  defp short_criterion("Substrate & Print Process"), do: "Surface"
  defp short_criterion("Defects"), do: "Defects"
  defp short_criterion(criterion), do: criterion

  defp display_status(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.downcase()
    |> String.capitalize()
  end

  defp display_status(_), do: "Unknown"

  defp visible_checks(checks) do
    checks
    |> List.wrap()
    |> Enum.reject(&(&1["criterion"] == "Barcode Dimensions"))
    |> Enum.with_index()
    |> Enum.sort_by(fn {check, index} -> {status_rank(check["status"]), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp status_rank("PASS"), do: 0
  defp status_rank("WARNING"), do: 1
  defp status_rank("FAIL"), do: 2
  defp status_rank("CANNOT_DETERMINE"), do: 3
  defp status_rank(_), do: 4

  defp gtin_attributes(product, detected_gtin) do
    product = product || %{}

    [
      %{label: "GTIN", value: product[:gtin] || detected_gtin, kind: :text},
      %{label: "Brand name", value: product[:brand], kind: :text},
      %{label: "Product description", value: product[:description], kind: :text},
      %{label: "Product image URL", value: product[:image_url], kind: :link},
      %{label: "Product category", value: product[:category], kind: :text},
      %{label: "Net content", value: product[:net_content], kind: :text},
      %{label: "Country of sale", value: product[:country_of_sale], kind: :text}
    ]
    |> Enum.with_index()
    |> Enum.map(fn {attribute, index} ->
      attribute
      |> Map.put(:index, index)
      |> Map.put(:missing, blank_value?(attribute.value))
    end)
    |> Enum.sort_by(fn attribute -> {if(attribute.missing, do: 0, else: 1), attribute.index} end)
  end

  defp available_attribute_count(attributes) do
    Enum.count(attributes, &(not &1.missing))
  end

  defp blank_value?(value), do: value in [nil, "", []]

  defp vision_module do
    Application.get_env(:verify_barcodes, :vision_client, VerifyBarcodes.OpenAI.Vision)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-50 py-4 md:py-8">
      <div class="mx-auto max-w-5xl space-y-4 px-4 sm:px-6">
        <%= if @status != :idle or @uploads.barcode_image.entries == [] do %>
          <section class="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
            <div class="grid gap-4 md:grid-cols-[auto_1fr] md:items-center">
              <div class="flex h-16 w-16 items-center justify-center rounded-2xl bg-gs1-blue-soft/45">
                <img
                  src={~p"/images/gs1.png"}
                  alt="GS1 logo"
                  class="max-h-full w-auto object-contain"
                />
              </div>

              <div class="space-y-2">
                <div class="text-xs font-semibold uppercase tracking-[0.22em] text-gs1-blue">
                  GS1 Kenya Barcode Verifier
                </div>
                <h1 class="text-3xl font-semibold tracking-[-0.04em] text-gs1-ink">
                  Check if your barcode is market-ready
                </h1>
                <p class="max-w-3xl text-sm leading-6 text-slate-600">
                  Upload a product barcode image for a quick GS1/ISO pre-check of scan quality, spacing, placement, and GTIN match.
                </p>
              </div>
            </div>
          </section>
        <% end %>

        <%= if @status == :idle do %>
          <form id="upload-form" phx-change="validate" phx-submit="analyse" class="space-y-4">
            <div class={[
              "rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6",
              if(@uploads.barcode_image.entries == [], do: "block", else: "hidden")
            ]}>
              <div class="grid gap-5 lg:grid-cols-[0.95fr_1.05fr] lg:items-start">
                <div class="space-y-4">
                  <div class="space-y-2">
                    <div class="text-sm font-semibold text-gs1-ink">1. Choose the pack shape</div>
                    <p class="text-sm leading-6 text-slate-600">
                      We use this to judge whether the barcode is placed correctly on a flat or curved product.
                    </p>
                  </div>

                  <div class="grid gap-3 sm:grid-cols-3 lg:grid-cols-1">
                    <label class={[
                      "cursor-pointer rounded-2xl border p-4 transition hover:border-gs1-blue/30 hover:bg-white hover:shadow-sm",
                      if(@surface_type == "straight",
                        do:
                          "border-gs1-blue bg-white ring-2 ring-gs1-blue/20 shadow-[0_10px_24px_-18px_rgba(37,99,235,0.65)]",
                        else: "border-slate-200 bg-slate-50"
                      )
                    ]}>
                      <input
                        type="radio"
                        name="surface_type"
                        value="straight"
                        checked={@surface_type == "straight"}
                        class="sr-only"
                      />
                      <div class="flex items-start justify-between gap-3">
                        <div class="text-sm font-semibold text-gs1-ink">Flat / straight</div>
                        <div
                          :if={@surface_type == "straight"}
                          class="inline-flex items-center gap-1 rounded-full bg-gs1-blue px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.12em] text-white"
                        >
                          <.icon name="hero-check-mini" class="h-3.5 w-3.5" /> Selected
                        </div>
                      </div>
                      <div class={[
                        "mt-1 text-sm",
                        if(@surface_type == "straight", do: "text-slate-700", else: "text-slate-500")
                      ]}>
                        Boxes, labels, cartons, cards.
                      </div>
                    </label>

                    <label class={[
                      "cursor-pointer rounded-2xl border p-4 transition hover:border-gs1-blue/30 hover:bg-white hover:shadow-sm",
                      if(@surface_type == "curved",
                        do:
                          "border-gs1-blue bg-white ring-2 ring-gs1-blue/20 shadow-[0_10px_24px_-18px_rgba(37,99,235,0.65)]",
                        else: "border-slate-200 bg-slate-50"
                      )
                    ]}>
                      <input
                        type="radio"
                        name="surface_type"
                        value="curved"
                        checked={@surface_type == "curved"}
                        class="sr-only"
                      />
                      <div class="flex items-start justify-between gap-3">
                        <div class="text-sm font-semibold text-gs1-ink">Curved</div>
                        <div
                          :if={@surface_type == "curved"}
                          class="inline-flex items-center gap-1 rounded-full bg-gs1-blue px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.12em] text-white"
                        >
                          <.icon name="hero-check-mini" class="h-3.5 w-3.5" /> Selected
                        </div>
                      </div>
                      <div class={[
                        "mt-1 text-sm",
                        if(@surface_type == "curved", do: "text-slate-700", else: "text-slate-500")
                      ]}>
                        Bottles, cans, jars, tubes.
                      </div>
                    </label>

                    <label class={[
                      "cursor-pointer rounded-2xl border p-4 transition hover:border-gs1-blue/30 hover:bg-white hover:shadow-sm",
                      if(@surface_type == "unknown",
                        do:
                          "border-gs1-blue bg-white ring-2 ring-gs1-blue/20 shadow-[0_10px_24px_-18px_rgba(37,99,235,0.65)]",
                        else: "border-slate-200 bg-slate-50"
                      )
                    ]}>
                      <input
                        type="radio"
                        name="surface_type"
                        value="unknown"
                        checked={@surface_type == "unknown"}
                        class="sr-only"
                      />
                      <div class="flex items-start justify-between gap-3">
                        <div class="text-sm font-semibold text-gs1-ink">Not sure</div>
                        <div
                          :if={@surface_type == "unknown"}
                          class="inline-flex items-center gap-1 rounded-full bg-gs1-blue px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.12em] text-white"
                        >
                          <.icon name="hero-check-mini" class="h-3.5 w-3.5" /> Selected
                        </div>
                      </div>
                      <div class={[
                        "mt-1 text-sm",
                        if(@surface_type == "unknown", do: "text-slate-700", else: "text-slate-500")
                      ]}>
                        We will still check what we can.
                      </div>
                    </label>
                  </div>
                </div>

                <div class="space-y-4">
                  <div class="space-y-2">
                    <div class="text-sm font-semibold text-gs1-ink">
                      2. Upload the barcode image
                    </div>
                    <p class="text-sm leading-6 text-slate-600">
                      We check quiet zones, contrast, print quality, placement, and GTIN validity.
                    </p>
                    <p class="text-xs leading-5 text-slate-500">
                      Formal ISO/IEC grades still require a compliant barcode verifier.
                    </p>
                  </div>

                  <label
                    for={@uploads.barcode_image.ref}
                    phx-drop-target={@uploads.barcode_image.ref}
                    class="flex min-h-[13rem] cursor-pointer flex-col items-center justify-center rounded-2xl border border-dashed border-slate-300 bg-slate-50 px-6 py-8 text-center transition hover:border-gs1-blue/35 hover:bg-white"
                  >
                    <div class="text-lg font-semibold tracking-[-0.02em] text-gs1-ink">
                      Upload product barcode
                    </div>
                    <div class="mt-2 max-w-md text-sm leading-6 text-slate-600">
                      Drag and drop here, or click to browse.
                    </div>
                    <div class="mt-4 text-xs font-medium uppercase tracking-[0.18em] text-slate-500">
                      JPG, PNG, WebP up to 5MB
                    </div>
                    <.live_file_input
                      upload={@uploads.barcode_image}
                      class="hidden"
                      capture="environment"
                    />
                  </label>

                  <button
                    type="submit"
                    disabled={@uploads.barcode_image.entries == []}
                    class="w-full rounded-2xl bg-gs1-blue px-6 py-3 text-base font-semibold text-white transition hover:bg-gs1-blue-dark disabled:cursor-not-allowed disabled:bg-slate-300"
                  >
                    Check barcode
                  </button>
                </div>
              </div>
            </div>

            <%= if @uploads.barcode_image.entries != [] do %>
              <%= for entry <- @uploads.barcode_image.entries do %>
                <div class="rounded-3xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
                  <div class="grid gap-4 sm:gap-5 lg:grid-cols-[15rem_1fr] lg:items-start">
                    <div class="overflow-hidden rounded-2xl border border-slate-200 bg-slate-50">
                      <.live_img_preview
                        entry={entry}
                        class="h-40 w-full object-contain p-2 sm:h-56 sm:p-3"
                      />
                    </div>

                    <div class="space-y-3 sm:space-y-4">
                      <div>
                        <div class="text-sm font-semibold text-gs1-ink">Ready to check</div>
                        <div class="mt-1 text-sm leading-6 text-slate-600">
                          Review the preview, then run the barcode check.
                        </div>
                      </div>

                      <div class="rounded-2xl border border-slate-200 bg-slate-50 px-3 py-3 text-sm text-slate-600 sm:px-4">
                        <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-3">
                          <div class="min-w-0 flex-1">
                            <div class="truncate font-medium text-gs1-ink">{entry.client_name}</div>
                            <div class="mt-1">
                              {Float.round(entry.client_size / 1_000_000, 2)} MB
                              <span class="mx-2 text-slate-300">•</span>
                            </div>
                          </div>
                          <div class="text-xs font-semibold uppercase tracking-[0.14em] text-gs1-blue sm:whitespace-nowrap">
                            {entry.progress}% uploaded
                          </div>
                        </div>

                        <div class="mt-3 h-2 overflow-hidden rounded-full bg-slate-200">
                          <div
                            class="h-full rounded-full bg-gs1-blue transition-all duration-300"
                            style={"width: #{entry.progress}%"}
                          >
                          </div>
                        </div>
                      </div>

                      <div class="flex flex-col gap-3 sm:flex-row">
                        <button
                          type="submit"
                          class="w-full flex-1 rounded-2xl bg-gs1-blue px-5 py-3 text-base font-semibold text-white transition hover:bg-gs1-blue-dark"
                        >
                          Check barcode
                        </button>
                        <button
                          type="button"
                          phx-click="cancel-upload"
                          phx-value-ref={entry.ref}
                          class="w-full rounded-2xl border border-slate-200 bg-white px-5 py-3 text-sm font-semibold text-slate-700 transition hover:bg-slate-50 sm:w-auto"
                        >
                          Choose different image
                        </button>
                      </div>
                    </div>
                  </div>
                </div>

                <%= for err <- upload_errors(@uploads.barcode_image, entry) do %>
                  <div class="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                    {error_to_string(err)}
                  </div>
                <% end %>
              <% end %>
            <% end %>

            <%= for err <- upload_errors(@uploads.barcode_image) do %>
              <div class="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                {error_to_string(err)}
              </div>
            <% end %>

            <%= if @error_message do %>
              <div class="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                {@error_message}
              </div>
            <% end %>
          </form>
        <% end %>

        <%= if @status == :analysing do %>
          <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8">
            <div class="grid gap-6 md:grid-cols-[1.1fr_0.9fr] md:items-center">
              <div>
                <div class="text-sm font-medium text-gs1-blue">Analysis in progress</div>
                <h2 class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-ink">
                  Analysing your barcode
                </h2>
                <p class="mt-2 text-sm leading-6 text-slate-600">
                  Checking contrast, margins, print quality, placement, and defects with your surface selection in mind.
                </p>

                <div class="mt-5 flex items-center gap-3">
                  <div class="h-7 w-7 animate-spin rounded-full border-2 border-slate-200 border-t-gs1-blue">
                  </div>
                  <div class="text-sm font-medium text-slate-700">Running verification checks</div>
                </div>
              </div>

              <%= if @preview_url do %>
                <img
                  src={@preview_url}
                  alt="Barcode preview"
                  class="max-h-72 w-full rounded-2xl border border-slate-200 bg-slate-50 object-contain p-4"
                />
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @status == :complete and @result do %>
          <% gtin_attributes = gtin_attributes(@product, @detected_gtin) %>
          <% checks = visible_checks(@result["checks"]) %>
          <div class="space-y-4">
            <%= if @gtin_status == :verifying do %>
              <div class="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div class="flex items-center gap-3">
                  <div class="h-5 w-5 animate-spin rounded-full border-2 border-slate-200 border-t-gs1-blue">
                  </div>
                  <div class="text-sm font-medium text-slate-700">
                    Looking up GTIN in the GS1 registry…
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @gtin_status == :verified and @product do %>
              <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-7">
                <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                  <div>
                    <div class="text-xs font-semibold uppercase tracking-[0.2em] text-gs1-blue">
                      Verified by GS1
                    </div>
                    <h2 class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-ink">
                      GTIN match
                    </h2>
                    <p class="mt-2 text-sm leading-6 text-slate-600">
                      The seven product attributes are shown here, with missing fields first.
                    </p>
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="inline-flex rounded-full bg-gs1-blue px-3 py-1 text-xs font-semibold uppercase tracking-[0.16em] text-white">
                      Verified
                    </span>
                    <span class="inline-flex rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-600">
                      {available_attribute_count(gtin_attributes)}/7 available
                    </span>
                  </div>
                </div>

                <div class="mt-6 grid gap-6 lg:grid-cols-[15rem_1fr]">
                  <div class="space-y-3">
                    <%= if @product.image_url do %>
                      <img
                        src={@product.image_url}
                        alt={@product.brand || "Product image"}
                        class="h-52 w-full rounded-2xl border border-slate-200 bg-slate-50 object-contain p-3"
                      />
                    <% else %>
                      <div class="flex h-52 w-full items-center justify-center rounded-2xl border border-dashed border-slate-300 bg-slate-50 text-xs font-medium uppercase tracking-[0.18em] text-slate-400">
                        Image missing
                      </div>
                    <% end %>

                    <%= if @product.licensee do %>
                      <div class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-3">
                        <div class="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">
                          Licensee
                        </div>
                        <div class="mt-1 text-sm font-medium text-gs1-ink">{@product.licensee}</div>
                      </div>
                    <% end %>
                  </div>

                  <div class="space-y-3">
                    <div class="grid gap-3 sm:grid-cols-2">
                      <%= for attribute <- gtin_attributes do %>
                        <div class={[
                          "rounded-2xl border px-4 py-4",
                          if(attribute.missing,
                            do: "border-gs1-orange/25 bg-gs1-orange-soft/35",
                            else: "border-slate-200 bg-slate-50"
                          )
                        ]}>
                          <div class="flex items-start justify-between gap-3">
                            <div class="text-xs font-semibold uppercase tracking-[0.16em] text-slate-500">
                              {attribute.label}
                            </div>
                            <span class={[
                              "inline-flex rounded-full px-2.5 py-1 text-[11px] font-semibold uppercase tracking-[0.12em]",
                              if(attribute.missing,
                                do: "bg-white text-gs1-orange-dark",
                                else: "bg-white text-slate-500"
                              )
                            ]}>
                              {if attribute.missing, do: "Missing", else: "Available"}
                            </span>
                          </div>

                          <div class="mt-3 text-sm leading-6 text-gs1-ink">
                            <%= cond do %>
                              <% attribute.missing -> %>
                                <span class="text-slate-500">
                                  No value available from Verified by GS1.
                                </span>
                              <% attribute.kind == :link -> %>
                                <a
                                  href={attribute.value}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  class="break-all text-gs1-blue underline decoration-gs1-blue/30 underline-offset-4"
                                >
                                  {attribute.value}
                                </a>
                              <% attribute.label == "GTIN" -> %>
                                <span class="font-mono">{attribute.value}</span>
                              <% true -> %>
                                {attribute.value}
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>

            <%= if @gtin_status == :not_verified do %>
              <div class="rounded-3xl border border-gs1-orange/25 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium uppercase tracking-[0.16em] text-gs1-orange-dark">
                  Not in GS1 Registry
                </div>
                <p class="mt-2 text-sm leading-6 text-slate-700">
                  GTIN <span class="font-mono">{@detected_gtin}</span>
                  is a valid number but was not found in the GS1 verified registry.
                </p>
              </div>
            <% end %>

            <%= if @gtin_status == :invalid do %>
              <div class="rounded-3xl border border-gs1-orange/25 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium uppercase tracking-[0.16em] text-gs1-orange-dark">
                  Invalid GTIN
                </div>
                <p class="mt-2 text-sm leading-6 text-slate-700">
                  The digits read from the barcode
                  <%= if @detected_gtin do %>
                    (<span class="font-mono">{@detected_gtin}</span>)
                  <% end %>
                  are not a valid GS1 GTIN (check digit does not match).
                </p>
              </div>
            <% end %>

            <%= if @gtin_status == :no_gtin do %>
              <div class="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium uppercase tracking-[0.16em] text-slate-500">
                  No GTIN Detected
                </div>
                <p class="mt-2 text-sm leading-6 text-slate-700">
                  We could not read a legible GTIN from the image, so a GS1 registry lookup was skipped.
                  Try a sharper photo with the digits under the barcode clearly visible.
                </p>
              </div>
            <% end %>

            <div class={"rounded-3xl border p-6 shadow-sm #{verdict_class(@result["overall_verdict"])}"}>
              <div class="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
                <div>
                  <div class="text-sm font-medium uppercase tracking-[0.16em] opacity-70">
                    Overall Verdict
                  </div>
                  <div class="mt-2 text-3xl font-semibold tracking-[-0.03em]">
                    {display_status(@result["overall_verdict"])}
                  </div>
                  <p class="mt-3 max-w-2xl text-sm leading-6 opacity-90">
                    {@result["summary"]}
                  </p>
                </div>
                <div class="rounded-2xl border border-current/10 bg-white/60 px-4 py-3">
                  <div class="text-xs font-medium uppercase tracking-[0.16em] opacity-70">
                    Score
                  </div>
                  <div class="mt-1 text-3xl font-semibold tracking-[-0.03em]">
                    {@result["overall_score"]}<span class="text-base font-medium opacity-70">/100</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="grid gap-4 md:grid-cols-[0.9fr_1.1fr]">
              <div class="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium text-gs1-blue">
                  Submitted image
                </div>
                <%= if @preview_url do %>
                  <img
                    src={@preview_url}
                    alt="Barcode"
                    class="mt-4 max-h-72 w-full rounded-2xl border border-slate-200 bg-slate-50 object-contain p-4"
                  />
                <% end %>
              </div>

              <div class="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium text-gs1-blue">Summary</div>
                <dl class="mt-4 grid gap-3 sm:grid-cols-2">
                  <div class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-4">
                    <dt class="text-sm text-slate-600">Passed checks</dt>
                    <dd class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-ink">
                      {count_status(checks, "PASS")}
                    </dd>
                  </div>
                  <div class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-4">
                    <dt class="text-sm text-slate-600">Warnings</dt>
                    <dd class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-orange-dark">
                      {count_status(checks, "WARNING")}
                    </dd>
                  </div>
                  <div class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-4">
                    <dt class="text-sm text-slate-600">Failed checks</dt>
                    <dd class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-orange-dark">
                      {count_status(checks, "FAIL")}
                    </dd>
                  </div>
                  <div class="rounded-2xl border border-slate-200 bg-slate-50 px-4 py-4">
                    <dt class="text-sm text-slate-600">Could not determine</dt>
                    <dd class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-ink">
                      {count_status(checks, "CANNOT_DETERMINE")}
                    </dd>
                  </div>
                </dl>
              </div>
            </div>

            <div class="rounded-3xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6">
              <div class="flex items-center justify-between gap-4">
                <h2 class="text-lg font-semibold text-gs1-ink">Checks</h2>
                <div class="text-xs font-medium uppercase tracking-[0.16em] text-slate-400">
                  {length(checks)} visible criteria
                </div>
              </div>
              <div class="mt-4 space-y-3">
                <%= for check <- checks do %>
                  <div class={"rounded-2xl border p-4 #{status_border(check["status"])}"}>
                    <div class="flex items-start gap-3">
                      <div class="mt-0.5 text-base leading-none">{status_icon(check["status"])}</div>
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                          <h3 class="text-base font-semibold tracking-[-0.01em] text-gs1-ink">
                            {short_criterion(check["criterion"])}
                          </h3>
                          <span class={"inline-flex w-fit rounded-full px-3 py-1 text-xs font-semibold uppercase tracking-[0.16em] #{status_badge(check["status"])}"}>
                            {display_status(check["status"])}
                          </span>
                        </div>
                        <p class="mt-2 text-sm leading-6 text-slate-600">
                          {check["finding"]}
                        </p>
                        <%= if check["recommendation"] not in [nil, "", "null"] do %>
                          <div class="mt-3 rounded-lg border border-gs1-orange/20 bg-gs1-orange-soft/40 px-4 py-3 text-sm leading-6 text-slate-700">
                            <span class="font-semibold text-gs1-orange-dark">Recommendation:</span>
                            {check["recommendation"]}
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <button
              phx-click="reset"
              class="w-full rounded-2xl border border-slate-200 bg-white px-6 py-3 text-base font-semibold text-gs1-blue transition hover:bg-slate-50"
            >
              Analyse another barcode
            </button>
          </div>
        <% end %>

        <%= if @status == :error do %>
          <div class="rounded-3xl border border-red-200 bg-white p-6 text-center shadow-sm">
            <div class="text-sm font-medium text-red-700">Something went wrong</div>
            <div class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-slate-900">
              Analysis failed
            </div>
            <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-slate-600">
              {@error_message}
            </p>
            <button
              phx-click="reset"
              class="mt-6 w-full rounded-2xl bg-gs1-blue px-6 py-3 text-base font-semibold text-white transition hover:bg-gs1-blue-dark"
            >
              Try again
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
