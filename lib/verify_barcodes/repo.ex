defmodule VerifyBarcodes.Repo do
  use Ecto.Repo,
    otp_app: :verify_barcodes,
    adapter: Ecto.Adapters.Postgres
end
