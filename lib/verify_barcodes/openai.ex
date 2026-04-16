defmodule VerifyBarcodes.OpenAI do
  require Logger

  def send_request_to_openai(context, prompt, opts \\ []) do
    api_url = "https://api.openai.com/v1/chat/completions"
    api_key = System.get_env("OPENAI_API_KEY")

    # Voice calls can pass a smaller max_tokens for lower latency (e.g. 150 for ~25 words)
    max_tokens = Keyword.get(opts, :max_tokens, 4000)

    model =
      "gpt-4o-mini"

    body = %{
      "model" => model,
      "messages" => [
        %{
          "role" => "system",
          "content" => context
        },
        %{"role" => "user", "content" => prompt}
      ],
      "temperature" => 0.5,
      "max_tokens" => max_tokens
    }

    if !is_binary(api_key) or byte_size(api_key) == 0 do
      Logger.error("Missing OPENAI_API_KEY; cannot call OpenAI")
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
        max_retries: 10,
        receive_timeout: 60_000
      ]

      case Req.post(api_url, req_options) do
        {:ok, %{status: 200, body: response_body}} ->
          case response_body do
            %{"choices" => [%{"message" => %{"content" => content}} | _]} ->
              {:ok, content}

            %{"choices" => []} ->
              {:error, ""}
          end

        {:ok, %{status: _status, body: body}} ->
          Logger.warning("OpenAI error response: #{inspect(body)}")
          {:error, ""}

        {:error, reason} ->
          Logger.warning("OpenAI request error: #{inspect(reason)}")
          {:error, ""}
      end
    end
  end
end
