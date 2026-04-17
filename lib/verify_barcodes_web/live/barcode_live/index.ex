defmodule VerifyBarcodesWeb.BarcodeLive.Index do
  use VerifyBarcodesWeb, :live_view

  @user_prompt "Analyse the uploaded barcode image and return your structured verdict as JSON only."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:status, :idle)
     |> assign(:result, nil)
     |> assign(:error_message, nil)
     |> assign(:preview_url, nil)
     |> allow_upload(:barcode_image,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 5_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("analyse", _params, socket) do
    case uploaded_entries(socket, :barcode_image) do
      {[], [_ | _]} ->
        {:noreply, assign(socket, :error_message, "Upload is still in progress. Please wait.")}

      {[], []} ->
        {:noreply, assign(socket, :error_message, "Please select a file first.")}

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

            Task.start(fn ->
              result = vision_module.analyse_image(base64, media_type, @user_prompt)

              send(parent, {:analysis_complete, result})
            end)

            {:noreply,
             socket
             |> assign(:status, :analysing)
             |> assign(:preview_url, "data:#{media_type};base64,#{base64}")
             |> assign(:error_message, nil)}

          _ ->
            {:noreply, assign(socket, :error_message, "Please select a file first.")}
        end
    end
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:status, :idle)
     |> assign(:result, nil)
     |> assign(:preview_url, nil)
     |> assign(:error_message, nil)}
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
         |> assign(:result, result)}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:status, :error)
         |> assign(:error_message, message)}
    end
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

  def verdict_class("PASS"), do: "border-gs1-blue/20 bg-gs1-blue-soft text-gs1-ink"
  def verdict_class("FAIL"), do: "border-gs1-orange/25 bg-gs1-orange-soft text-gs1-ink"
  def verdict_class("WARNING"), do: "border-gs1-orange/25 bg-gs1-orange-soft text-gs1-ink"
  def verdict_class(_), do: "border-gs1-blue/15 bg-white text-gs1-ink"

  def status_icon("PASS"), do: "✅"
  def status_icon("FAIL"), do: "❌"
  def status_icon("WARNING"), do: "⚠️"
  def status_icon("CANNOT_DETERMINE"), do: "❓"
  def status_icon(_), do: "❓"

  def status_border("PASS"), do: "border-gs1-blue/20 bg-gs1-blue-soft/60"
  def status_border("FAIL"), do: "border-gs1-orange/25 bg-gs1-orange-soft/60"
  def status_border("WARNING"), do: "border-gs1-orange/25 bg-gs1-orange-soft/60"
  def status_border(_), do: "border-slate-200 bg-white"

  def status_badge("PASS"), do: "bg-gs1-blue text-white"
  def status_badge("FAIL"), do: "bg-gs1-orange text-white"
  def status_badge("WARNING"), do: "bg-gs1-orange text-white"
  def status_badge("CANNOT_DETERMINE"), do: "bg-slate-100 text-slate-600"
  def status_badge(_), do: "bg-slate-100 text-slate-600"

  defp count_status(checks, status) do
    Enum.count(checks || [], &(&1["status"] == status))
  end

  defp vision_module do
    Application.get_env(:verify_barcodes, :vision_client, VerifyBarcodes.OpenAI.Vision)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen py-6 md:py-10">
      <div class="mx-auto max-w-3xl space-y-5">
        <section class="rounded-2xl border border-gs1-blue/15 bg-white p-6 shadow-sm">
          <div>
            <div class="flex items-center gap-4">
              <div class="flex h-16 w-16 items-center justify-center rounded-xl  sm:h-20 sm:w-20">
                <img
                  src={~p"/images/gs1.png"}
                  alt="GS1 logo"
                  class="max-h-full w-auto object-contain"
                />
              </div>

              <p class="text-xl font-semibold tracking-[-0.02em] text-gs1-blue sm:text-2xl">
                GS1 barcode verifier
              </p>
            </div>

            <div class="mt-4">
              <h1 class="text-3xl font-semibold tracking-[-0.03em] text-gs1-ink">
                Verify one barcode image
              </h1>
              <p class="mt-3 max-w-2xl text-sm leading-6 text-slate-600">
                Upload a barcode image and review a short verdict, score, findings, and recommendations.
              </p>
            </div>
          </div>
        </section>

        <%= if @status == :idle do %>
          <form id="upload-form" phx-change="validate" phx-submit="analyse" class="space-y-4">
            <div class="rounded-2xl border border-gs1-blue/15 bg-white p-5 shadow-sm">
              <label
                for={@uploads.barcode_image.ref}
                phx-drop-target={@uploads.barcode_image.ref}
                class="flex min-h-[15rem] cursor-pointer flex-col items-center justify-center rounded-xl border-2 border-dashed border-gs1-blue/25 bg-gs1-blue-soft/35 px-6 py-10 text-center transition hover:border-gs1-orange/40 hover:bg-gs1-blue-soft/60"
              >
                <div class="text-lg font-semibold text-gs1-ink">Choose a barcode image</div>
                <div class="mt-2 max-w-md text-sm leading-6 text-slate-600">
                  Drag and drop here, or click to browse.
                </div>
                <div class="mt-4 text-xs font-medium uppercase tracking-[0.18em] text-gs1-orange-dark">
                  JPG, PNG, WebP up to 5MB
                </div>
                <.live_file_input upload={@uploads.barcode_image} class="hidden" />
              </label>
            </div>

            <%= for entry <- @uploads.barcode_image.entries do %>
              <div class="rounded-xl border border-gs1-blue/15 bg-white p-4 shadow-sm">
                <div class="flex flex-col gap-4 sm:flex-row sm:items-center">
                  <.live_img_preview
                    entry={entry}
                    class="h-20 w-20 rounded-lg border border-gs1-blue/15 bg-gs1-blue-soft/40 object-contain p-2"
                  />
                  <div class="min-w-0 flex-1">
                    <div class="truncate text-base font-medium text-gs1-ink">
                      {entry.client_name}
                    </div>
                    <div class="mt-1 text-sm text-slate-500">
                      {Float.round(entry.client_size / 1_000_000, 2)} MB
                    </div>
                    <div class="mt-3 h-2 w-full overflow-hidden rounded-full bg-slate-200">
                      <div
                        class="h-2 rounded-full bg-gs1-blue transition-all duration-300"
                        style={"width: #{entry.progress}%"}
                      >
                      </div>
                    </div>
                  </div>
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="inline-flex h-10 w-10 items-center justify-center rounded-full border border-gs1-blue/15 text-gs1-blue transition hover:border-gs1-orange/30 hover:bg-gs1-orange-soft hover:text-gs1-orange-dark"
                    aria-label="cancel"
                  >
                    ✕
                  </button>
                </div>
              </div>

              <%= for err <- upload_errors(@uploads.barcode_image, entry) do %>
                <div class="rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-700">
                  {error_to_string(err)}
                </div>
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

            <button
              type="submit"
              disabled={@uploads.barcode_image.entries == []}
              class="w-full rounded-xl bg-gs1-blue px-6 py-3 text-base font-semibold text-white transition hover:bg-gs1-blue-dark disabled:cursor-not-allowed disabled:bg-slate-300"
            >
              Analyse barcode
            </button>
          </form>
        <% end %>

        <%= if @status == :analysing do %>
          <div class="rounded-2xl border border-gs1-blue/15 bg-white p-6 shadow-sm">
            <div class="grid gap-6 md:grid-cols-[1.1fr_0.9fr] md:items-center">
              <div>
                <div class="text-sm font-medium text-gs1-orange-dark">Analysis in progress</div>
                <h2 class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-gs1-ink">
                  Analysing your barcode
                </h2>
                <p class="mt-2 text-sm leading-6 text-slate-600">
                  Checking contrast, quiet zones, symbol quality, placement, and print defects. This usually takes 5 to 15 seconds.
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
                  class="max-h-72 w-full rounded-xl border border-gs1-blue/15 bg-gs1-blue-soft/25 object-contain p-4"
                />
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @status == :complete and @result do %>
          <div class="space-y-4">
            <div class={"rounded-2xl border p-6 #{verdict_class(@result["overall_verdict"])}"}>
              <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
                <div>
                  <div class="text-sm font-medium uppercase tracking-[0.16em] opacity-70">
                    Overall Verdict
                  </div>
                  <div class="mt-2 text-3xl font-semibold tracking-[-0.03em]">
                    {@result["overall_verdict"]}
                  </div>
                  <p class="mt-3 max-w-2xl text-sm leading-6 opacity-90">
                    {@result["summary"]}
                  </p>
                </div>
                <div class="rounded-xl border border-current/10 bg-white/50 px-4 py-3">
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
              <div class="rounded-2xl border border-gs1-blue/15 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium text-gs1-blue">
                  Submitted image
                </div>
                <%= if @preview_url do %>
                  <img
                    src={@preview_url}
                    alt="Barcode"
                    class="mt-4 max-h-72 w-full rounded-xl border border-gs1-blue/15 bg-gs1-blue-soft/25 object-contain p-4"
                  />
                <% end %>
              </div>

              <div class="rounded-2xl border border-gs1-blue/15 bg-white p-5 shadow-sm">
                <div class="text-sm font-medium text-gs1-blue">Summary</div>
                <dl class="mt-4 space-y-3 text-sm">
                  <div class="flex items-center justify-between gap-4 border-b border-slate-100 pb-3">
                    <dt class="text-slate-600">Passed checks</dt>
                    <dd class="font-semibold text-gs1-ink">
                      {count_status(@result["checks"], "PASS")}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-4 border-b border-slate-100 pb-3">
                    <dt class="text-slate-600">Warnings</dt>
                    <dd class="font-semibold text-gs1-orange-dark">
                      {count_status(@result["checks"], "WARNING")}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-4 border-b border-slate-100 pb-3">
                    <dt class="text-slate-600">Failed checks</dt>
                    <dd class="font-semibold text-gs1-orange-dark">
                      {count_status(@result["checks"], "FAIL")}
                    </dd>
                  </div>
                  <div class="flex items-center justify-between gap-4">
                    <dt class="text-slate-600">Could not determine</dt>
                    <dd class="font-semibold text-gs1-ink">
                      {count_status(@result["checks"], "CANNOT_DETERMINE")}
                    </dd>
                  </div>
                </dl>
              </div>
            </div>

            <div class="rounded-2xl border border-gs1-blue/15 bg-white p-5 shadow-sm">
              <h2 class="text-lg font-semibold text-gs1-ink">Checks</h2>
              <div class="mt-4 space-y-3">
                <%= for check <- @result["checks"] || [] do %>
                  <div class={"rounded-xl border p-4 #{status_border(check["status"])}"}>
                    <div class="flex items-start gap-3">
                      <div class="min-w-0 flex-1">
                        <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
                          <h3 class="text-base font-semibold text-gs1-ink">
                            {check["criterion"]}
                          </h3>
                          <span class={"inline-flex w-fit rounded-full px-3 py-1 text-xs font-semibold uppercase tracking-[0.16em] #{status_badge(check["status"])}"}>
                            {check["status"]}
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
              class="w-full rounded-xl border border-gs1-blue/20 bg-white px-6 py-3 text-base font-semibold text-gs1-blue transition hover:bg-gs1-blue-soft/40"
            >
              Analyse another barcode
            </button>
          </div>
        <% end %>

        <%= if @status == :error do %>
          <div class="rounded-2xl border border-red-200 bg-white p-6 text-center">
            <div class="text-sm font-medium text-red-700">Something went wrong</div>
            <div class="mt-2 text-2xl font-semibold tracking-[-0.03em] text-slate-900">
              Analysis failed
            </div>
            <p class="mx-auto mt-3 max-w-xl text-sm leading-6 text-slate-600">
              {@error_message}
            </p>
            <button
              phx-click="reset"
              class="mt-6 w-full rounded-xl bg-gs1-blue px-6 py-3 text-base font-semibold text-white transition hover:bg-gs1-blue-dark"
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
