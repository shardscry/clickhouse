require "./app"

container = ADI::ServiceContainer.new
container.app.mount
Kemal.config.host_binding = ENV["HOST"]? || "127.0.0.1"
Kemal.config.port = (ENV["PORT"]? || "3000").to_i
Kemal.config.serve_static = false
Kemal.run
