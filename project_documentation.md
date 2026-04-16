# AI Barcode Verification System — Project Documentation

## Project Overview

Build an **AI-powered Barcode Verification System** using **Elixir**, **Phoenix LiveView**, and **OpenAI GPT-4o** (vision-capable model). Users upload an image of a barcode; the system analyses it against industry standards and returns a structured verdict — pass/fail, reasons, and actionable improvement recommendations.

---

## Tech Stack

| Layer         | Technology                           |
| ------------- | ------------------------------------ |
| Language      | Elixir                               |
| Web Framework | Phoenix LiveView                     |
| AI Provider   | OpenAI GPT-4o (vision)               |
| HTTP Client   | Req                                  |
| File Upload   | Phoenix LiveView `allow_upload/3`    |
| Styling       | Tailwind CSS (default Phoenix setup) |

---

## Existing Code — Do Not Regenerate

The project already has an OpenAI client module. Reuse it as-is:

```elixir
# lib/verify_barcodes/openai.ex
defmodule VerifyBarcodes.OpenAI do
  require Logger

  def send_request_to_openai(context, prompt, opts \\ []) do
    api_url = "https://api.openai.com/v1/chat/completions"
    api_key = System.get_env("OPENAI_API_KEY")
    max_tokens = Keyword.get(opts, :max_tokens, 4000)
    model = "gpt-4o-mini"

    body = %{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => context},
        %{"role" => "user", "content" => prompt}
      ],
      "temperature" => 0.5,
      "max_tokens" => max_tokens
    }

    # ... (full implementation already exists)
  end
end
```

> **Important:** The existing module sends text-only prompts. For image analysis, we need to create a **new function** `send_vision_request/3` that sends a multipart message with both an image (base64) and a text prompt using the OpenAI vision API format. Do NOT modify the existing `send_request_to_openai/3`.

---

## New Module to Create

### `VerifyBarcodes.OpenAI.Vision`

Create `lib/verify_barcodes/openai/vision.ex`:

```elixir
defmodule VerifyBarcodes.OpenAI.Vision do
  @doc """
  Sends an image (base64-encoded) + text prompt to OpenAI GPT-4o vision endpoint.
  Returns {:ok, response_text} or {:error, reason}.
  """
  def analyse_image(base64_image, media_type, prompt, system_prompt) do
    # Use model: "gpt-4o" (NOT gpt-4o-mini — vision requires gpt-4o)
    # Message format:
    # messages: [
    #   %{"role" => "system", "content" => system_prompt},
    #   %{"role" => "user", "content" => [
    #       %{"type" => "image_url", "image_url" => %{"url" => "data:#{media_type};base64,#{base64_image}"}},
    #       %{"type" => "text", "text" => prompt}
    #   ]}
    # ]
  end
end
```

---

## Barcode Verification Logic

### System Prompt for OpenAI

The system prompt must instruct GPT-4o to act as a barcode quality expert and evaluate the uploaded image against ALL of the following criteria:

1. **Barcode Dimensions** — Is magnification within 80%–200%? Is the X-dimension (module width) compliant?
2. **Colour & Contrast** — Are bars dark on a light background? Is black-on-white used?
3. **Quiet Zones** — Are clear margins present on both sides, proportional to X-dimension?
4. **Placement Orientation** — Picket fence for flat surfaces; ladder for curved surfaces >30°; not near edges or seams.
5. **Symbology** — Correct symbology for use case: EAN/UPC (point-of-sale), ITF-14 (logistics), GS1-128 (logistics data), DataMatrix (healthcare).
6. **Truncation** — Is the barcode height above the minimum threshold?
7. **Symbol Contrast** — Is there sufficient reflectance difference between bars and spaces?
8. **Print Quality** — Does it appear to meet ISO/IEC minimum Grade C?
9. **Human Readable Interpretation (HRI)** — Is legible text present below the barcode?
10. **Bar Width Reduction** — Is there evidence of ink spread compensation applied?
11. **Substrate & Print Process** — Does the material/print method appear suitable?
12. **Defects** — Are there smudges, voids, or print inconsistencies?

### Response Format from AI

Instruct OpenAI to return a **structured JSON response only** (no markdown, no preamble):

```json
{
  "overall_verdict": "PASS" | "FAIL" | "WARNING",
  "overall_score": 85,
  "summary": "Brief overall summary sentence.",
  "checks": [
    {
      "criterion": "Barcode Dimensions",
      "status": "PASS" | "FAIL" | "WARNING" | "CANNOT_DETERMINE",
      "finding": "What was observed.",
      "recommendation": "What to fix or improve (null if passing)."
    }
  ]
}
```

Parse this JSON in Elixir after receiving the response.

---

## Phoenix LiveView — UI & Upload Flow

### Route

```elixir
# router.ex
live "/barcode-verify", BarcodeLive.Index
```

### LiveView Module

**File:** `lib/verify_barcodes_web/live/barcode_live/index.ex`

#### State (socket assigns)

```elixir
%{
  upload: configured via allow_upload,
  status: :idle | :uploading | :analysing | :complete | :error,
  result: nil | %{verdict: ..., score: ..., summary: ..., checks: [...]},
  preview_url: nil | binary,
  error_message: nil | binary
}
```

#### Upload Configuration

```elixir
socket
|> allow_upload(:barcode_image,
    accept: ~w(.jpg .jpeg .png .webp),
    max_entries: 1,
    max_file_size: 5_000_000  # 5MB
  )
```

#### Handle Events

- `"validate"` — Called on file selection; used for live validation feedback.
- `"analyse"` — Triggered on form submit. Should:
  1. Consume the uploaded file, read binary, Base64-encode it.
  2. Detect MIME type from file extension.
  3. Call `VerifyBarcodes.OpenAI.Vision.analyse_image/4` in an async `Task`.
  4. Set `status: :analysing` while waiting.
- `"analysis_complete"` — Sent by the async Task via `send(self(), ...)`. Parse JSON, set `result` and `status: :complete`.
- `"reset"` — Clears all assigns back to idle state.

---

## UI Design

Use **Tailwind CSS**. The UI should have three states:

### 1. Upload State (`:idle`)

- Drag-and-drop upload zone with dashed border
- "Upload a barcode image to verify" headline
- Accepted formats note: JPG, PNG, WebP, max 5MB
- Large "Analyse Barcode" submit button (disabled until file selected)
- Live file preview thumbnail once file is selected

### 2. Loading State (`:analysing`)

- Show the uploaded image preview
- Animated spinner
- "Analysing barcode against GS1 standards…" message

### 3. Results State (`:complete`)

- **Verdict Banner** at top:
  - PASS → green background
  - FAIL → red background
  - WARNING → amber background
  - Show overall score (e.g. "85/100") and summary sentence
- **Checks Grid** — a card for each of the 12 criteria:
  - Icon: ✅ PASS, ❌ FAIL, ⚠️ WARNING, ❓ CANNOT_DETERMINE
  - Criterion name as card title
  - Finding text
  - Recommendation text (highlighted in amber if present)
- **"Analyse Another" button** to reset

---

## File Structure to Create

```
lib/
  verify_barcodes/
    openai/
      vision.ex                        ← NEW: vision API client
  verify_barcodes_web/
    live/
      barcode_live/
        index.ex                       ← NEW: LiveView module
        index.html.heex                ← NEW: LiveView template
```

---

## Implementation Notes

- **Do not use `gpt-4o-mini` for vision** — it does not support image inputs reliably. Use `"gpt-4o"` in the Vision module.
- **Base64 encoding** in Elixir: `Base.encode64(binary)`.
- **Async pattern**: Use `Task.async` or `send(self(), msg)` pattern to avoid blocking the LiveView process during the API call.
- **JSON parsing**: Use `Jason.decode!/1` on the AI response. Wrap in a rescue to handle malformed responses gracefully.
- **Error handling**: If the AI returns a non-JSON response or the API fails, set `status: :error` with a user-friendly message.
- **MIME type detection**: Infer from the upload entry's `client_type` field (e.g. `"image/jpeg"`).

---

## Environment Variables Required

```
OPENAI_API_KEY=sk-...
```

Add to `.env` / `config/runtime.exs`.

---

## Example Jason Decode Pattern

```elixir
defp parse_ai_response(raw_text) do
  raw_text
  |> String.trim()
  |> Jason.decode()
  |> case do
    {:ok, %{"overall_verdict" => verdict, "checks" => checks} = result} ->
      {:ok, result}
    {:ok, _unexpected} ->
      {:error, "Unexpected response structure from AI"}
    {:error, _} ->
      {:error, "AI returned non-JSON response"}
  end
end
```

---

## Checklist for Claude Code

- [ ] Create `lib/verify_barcodes/openai/vision.ex` with `analyse_image/4`
- [ ] Create `lib/verify_barcodes_web/live/barcode_live/index.ex` with full LiveView
- [ ] Create `lib/verify_barcodes_web/live/barcode_live/index.html.heex` with Tailwind UI
- [ ] Add route in `router.ex`
- [ ] Verify `Jason` is in `mix.exs` dependencies (add if missing)
- [ ] Verify `Req` is in `mix.exs` dependencies (add if missing)
- [ ] Do not modify existing `VerifyBarcodes.OpenAI` module

---

## References

- OpenAI Vision API: https://platform.openai.com/docs/guides/vision
- Phoenix LiveView Uploads: https://hexdocs.pm/phoenix_live_view/uploads.html
- GS1 Barcode Standards: https://www.gs1.org/standards/barcodes
