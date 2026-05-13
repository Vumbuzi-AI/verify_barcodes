defmodule VerifyBarcodes.OpenAI.Vision do
  @moduledoc """
  OpenAI vision client for analysing barcode images with text prompts.
  """
  require Logger

  @api_url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-5.5"
  @analysis_context """
  You are a barcode quality expert with deep knowledge of GS1 standards and ISO/IEC 15416/15415.
  You will be given an image of a barcode to evaluate.

  Base every judgement strictly on evidence visible in the provided image.
  Never invent physical measurements, print-process settings, or production metadata that are not visible.

  Evaluate the barcode against ALL of the following 12 criteria:

  1. Barcode Dimensions — Is magnification within 80%–200%? Is the X-dimension (module width) compliant?
  2. Colour & Contrast — Are bars dark on a light background? Is black-on-white used?
  3. Quiet Zones — Are clear margins present on both sides, proportional to X-dimension?
  4. Placement Orientation — Picket fence for flat surfaces; ladder for curved surfaces >30°; not near edges or seams.
  5. Symbology — Correct symbology for use case: EAN/UPC (point-of-sale), ITF-14 (logistics), GS1-128 (logistics data), DataMatrix (healthcare).
  6. Truncation — Is the barcode height above the minimum threshold?
  7. Symbol Contrast — Is there sufficient reflectance difference between bars and spaces?
  8. Print Quality — Does it appear to meet ISO/IEC minimum Grade C?
  9. Human Readable Interpretation (HRI) — Is legible text present below the barcode?
  10. Bar Width Reduction — Is there evidence of ink spread compensation applied?
  11. Substrate & Print Process — Does the material/print method appear suitable?
  12. Defects — Are there smudges, voids, or print inconsistencies?

  Respond with STRICT JSON ONLY. No markdown fences, no preamble, no trailing commentary.

  Important evaluation rules:
  - Use "CANNOT_DETERMINE" only when the image genuinely lacks enough evidence to support a responsible assessment.
  - When using "CANNOT_DETERMINE", the "finding" must explicitly name what is missing, such as scale reference, production specifications, or visible substrate detail.
  - If a criterion cannot be confirmed exactly but the image still provides partial visual evidence, mention that evidence in the "finding" before stating the limitation.
  - Do not claim exact magnification, X-dimension, or physical size unless the image itself provides a reliable reference scale.
  - Do not claim bar width reduction, ink spread compensation, or print-process settings unless those are visually supported or strongly implied by the image.
  - Do not guess substrate type or print process when the material surface and production characteristics are not clearly visible.
  - Prefer specific, image-grounded findings over generic stock phrases.
  - Keep each "finding" concise: one sentence, ideally under 20 words.
  - Keep each "recommendation" concise: one sentence, ideally under 12 words.
  - Avoid weak hedging such as "appears fairly" or boilerplate such as "cannot be assessed from the image" without naming the exact missing evidence.

  Precision rules for common weak areas:
  - Barcode Dimensions: if there is no ruler, packaging dimension, or other scale reference, say that exact magnification/X-dimension cannot be verified because no scale reference is visible.
  - Bar Width Reduction: only judge this from visible bar edge shape, swelling, or print gain. If edges look clean but compensation cannot be proven, say that visible bar edges look clean but print compensation cannot be confirmed without print specs or a master reference.
  - Substrate & Print Process: mention the visible surface if it is obvious (for example glossy label, cardboard, flexible film). If not obvious, say that the surface detail is insufficient to identify material or print process.
  - For criteria that depend on production metadata rather than visible image evidence, do not repeat generic phrasing; state exactly which missing reference would be needed.

  Preferred style examples:
  - Good: "No scale reference is visible, so exact magnification cannot be verified."
  - Good: "Bar edges look clean, but print compensation cannot be confirmed without print specifications."
  - Good: "Surface detail is too limited to identify the substrate or print process."
  - Bad: "The image is tightly cropped around the symbol and does not show enough surface detail to identify the substrate or printing process reliably."

  Also read the GTIN digits from the human-readable interpretation (HRI) under the barcode
  if they are visible. Return only digits in the "gtin" field — no spaces or separators.
  If the digits are not legible in the image, return null.

  Schema:
  {
    "overall_verdict": "PASS" | "FAIL" | "WARNING",
    "overall_score": <integer 0-100>,
    "summary": "<one-sentence overall summary>",
    "gtin": "<digits only, or null if not legible>",
    "checks": [
      {
        "criterion": "<name exactly as listed above>",
        "status": "PASS" | "FAIL" | "WARNING" | "CANNOT_DETERMINE",
        "finding": "<what was observed>",
        "recommendation": "<fix or improvement, or null if passing>"
      }
    ]
  }

  The "checks" array must contain exactly 12 entries, one per criterion, in the same order.
  """

  @doc """
  Sends an image (base64-encoded) + text prompt to the configured OpenAI vision-capable model.

  ## Arguments
    * `base64_image` - Base64-encoded image binary
    * `media_type` - MIME type string (e.g. "image/jpeg", "image/png")
    * `prompt` - User prompt text

  Returns `{:ok, response_text}` or `{:error, reason}`.
  """
  def analyse_image(base64_image, media_type, prompt, opts \\ []) do
    api_key = System.get_env("OPENAI_API_KEY")
    max_tokens = Keyword.get(opts, :max_tokens, 4000)
    model = vision_model()

    body =
      %{
        "model" => model,
        "messages" => [
          %{"role" => "system", "content" => @analysis_context},
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "image_url",
                "image_url" => %{
                  "url" => "data:#{media_type};base64,#{base64_image}",
                  "detail" => image_detail(model)
                }
              },
              %{"type" => "text", "text" => prompt}
            ]
          }
        ]
      }
      |> put_completion_limit(model, max_tokens)

    if !is_binary(api_key) or byte_size(api_key) == 0 do
      Logger.error("Missing OPENAI_API_KEY; cannot call OpenAI Vision")
      {:error, :missing_openai_api_key}
    else
      headers = [
        {"Content-Type", "application/json"},
        {"Authorization", "Bearer #{api_key}"}
      ]

      req_options = [
        headers: headers,
        json: body,
        retry: :transient,
        max_retries: 3,
        receive_timeout: 120_000
      ]

      case Req.post(@api_url, req_options) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
          {:ok, content}

        {:ok, %{status: 200, body: %{"choices" => []}}} ->
          {:error, :empty_response}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("OpenAI Vision error #{status}: #{inspect(body)}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.warning("OpenAI Vision request error: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp vision_model do
    Application.get_env(
      :verify_barcodes,
      :vision_model,
      System.get_env("OPENAI_VISION_MODEL") || @default_model
    )
  end

  defp image_detail(model) do
    if String.starts_with?(model, "gpt-5.4") and
         not String.starts_with?(model, "gpt-5.4-mini") and
         not String.starts_with?(model, "gpt-5.4-nano") do
      "original"
    else
      "high"
    end
  end

  defp put_completion_limit(body, model, max_tokens) do
    if String.starts_with?(model, "gpt-5") do
      Map.put(body, "max_completion_tokens", max_tokens)
    else
      Map.put(body, "max_tokens", max_tokens)
    end
  end
end
