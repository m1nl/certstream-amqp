import Config

config :certstream_amqp,
       user_agent: :default  # Defaults to "Certstream-AMQP v{CURRENT_VERSION}"

config :logger,
       level: String.to_atom(System.get_env("LOG_LEVEL") || "info"),
       backends: [:console]

config :honeybadger,
       app: :certstream,
       exclude_envs: [:test],
       environment_name: :prod,
       use_logger: true,
       api_key: "test"

config :amqp,
       exchange: "certstream",
       channels: [
         amqp_channel: [connection: :amqp_connection]
       ]

# Disable connection pooling for HTTP requests
config :hackney, use_default_pool: false

import_config "#{config_env()}.exs"
