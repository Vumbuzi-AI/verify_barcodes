defmodule VerifyBarcodes.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VerifyBarcodesWeb.Telemetry,
      VerifyBarcodes.Repo,
      {DNSCluster, query: Application.get_env(:verify_barcodes, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: VerifyBarcodes.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: VerifyBarcodes.Finch},
      # Start a worker by calling: VerifyBarcodes.Worker.start_link(arg)
      # {VerifyBarcodes.Worker, arg},
      # Start to serve requests, typically the last entry
      VerifyBarcodesWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: VerifyBarcodes.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VerifyBarcodesWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
