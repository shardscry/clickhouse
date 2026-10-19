require "socket"
require "openssl"
require "../config"

module ClickHouse::Transport
  def self.open(config : ClickHouse::Config) : IO
    tcp = TCPSocket.new(config.host, config.port, connect_timeout: config.connect_timeout)
    tcp.read_timeout = config.read_timeout
    tcp.write_timeout = config.write_timeout
    tcp.tcp_nodelay = true
    tcp.sync = false
    return tcp unless config.tls?
    context = OpenSSL::SSL::Context::Client.new
    context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless config.tls_verify?
    if path = config.tls_ca
      context.ca_certificates = path
    end
    OpenSSL::SSL::Socket::Client.new(tcp, context, sync_close: true, hostname: config.tls_hostname || config.host)
  rescue ex
    tcp.try { |socket| socket.close rescue nil }
    raise ClickHouse::ConnectionError.new("could not connect to #{config.host}:#{config.port}", cause: ex)
  end
end
