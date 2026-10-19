require "uri"
require "./errors"

struct ClickHouse::Config
  getter host : String
  getter port : Int32
  getter database : String
  getter username : String
  getter password : String
  getter? tls : Bool
  getter? tls_verify : Bool
  getter tls_ca : String?
  getter tls_hostname : String?
  getter compression : Symbol
  getter connect_timeout : Time::Span
  getter read_timeout : Time::Span
  getter write_timeout : Time::Span
  getter query_timeout : Time::Span
  getter batch_size : Int32
  getter batch_bytes : Int32
  getter max_result_rows : Int32
  getter max_result_bytes : Int32

  def initialize(
    @host : String = "127.0.0.1",
    @port : Int32 = 9000,
    @database : String = "default",
    @username : String = "default",
    @password : String = "",
    @tls : Bool = false,
    @tls_verify : Bool = true,
    @tls_ca : String? = nil,
    @tls_hostname : String? = nil,
    @compression : Symbol = :none,
    @connect_timeout : Time::Span = 5.seconds,
    @read_timeout : Time::Span = 30.seconds,
    @write_timeout : Time::Span = 30.seconds,
    @query_timeout : Time::Span = 30.seconds,
    @batch_size : Int32 = 1000,
    @batch_bytes : Int32 = 8 * 1024 * 1024,
    @max_result_rows : Int32 = 1_000_000,
    @max_result_bytes : Int32 = 64 * 1024 * 1024,
  )
    raise ArgumentError.new("host cannot be empty") if @host.empty?
    raise ArgumentError.new("port must be 1..65535") unless 1 <= @port <= 65535
    raise ArgumentError.new("database cannot be empty") if @database.empty?
    raise ArgumentError.new("compression must be :none or :lz4") unless {:none, :lz4}.includes?(@compression)
    {@connect_timeout, @read_timeout, @write_timeout, @query_timeout}.each do |timeout|
      raise ArgumentError.new("timeouts must be positive") unless timeout > Time::Span.zero
    end
    raise ArgumentError.new("batch_size must be positive") unless @batch_size > 0
    raise ArgumentError.new("batch_bytes must be positive") unless @batch_bytes > 0
    raise ArgumentError.new("max_result_rows must be positive") unless @max_result_rows > 0
    raise ArgumentError.new("max_result_bytes must be positive") unless @max_result_bytes > 0
  end

  def self.from_string(
    value : String, *,
    tls_ca : String? = nil, tls_hostname : String? = nil,
    tls_verify : Bool? = nil, compression : Symbol? = nil, **options,
  ) : self
    uri, host = parse_uri(value)
    query = parse_options(uri.query)
    verify = tls_verify.nil? ? parse_tls_verify(query["tls_verify"]?) : tls_verify
    selected_compression = compression || parse_compression(query["compression"]?)
    secure = uri.scheme == "clickhouses"
    connection_options = {
      host: host.strip("[]"), port: uri.port || (secure ? 9440 : 9000),
      database: parse_database(uri.path), username: uri.user || "default",
      password: uri.password || "", tls: secure, tls_verify: verify,
      tls_ca: tls_ca || query["tls_ca"]?, tls_hostname: tls_hostname || query["tls_hostname"]?,
      compression: selected_compression,
    }
    new(**connection_options.merge(options))
  end

  private def self.parse_uri(value : String) : Tuple(URI, String)
    uri = URI.parse(preserve_authority_plus(value))
    raise ArgumentError.new("expected clickhouse:// or clickhouses:// URI") unless {"clickhouse", "clickhouses"}.includes?(uri.scheme)
    host = uri.host || raise ArgumentError.new("URI requires a host")
    raise ArgumentError.new("URI requires a host") if host.empty?
    raise ArgumentError.new("URI fragments are not supported") if uri.fragment
    {uri, host}
  end

  private def self.preserve_authority_plus(value : String) : String
    scheme, marker, remainder = value.partition("://")
    authority, separator, tail = remainder.partition(/[\/?#]/)
    # Crystal's URI parser form-decodes userinfo; literal plus is not a space there.
    "#{scheme}#{marker}#{authority.gsub("+", "%2B")}#{separator}#{tail}"
  end

  private def self.parse_options(query : String?) : URI::Params
    options = URI::Params.parse(query || "")
    options.each do |key, _|
      unless {"tls_ca", "tls_hostname", "tls_verify", "compression"}.includes?(key)
        raise ArgumentError.new("unsupported connection option #{key}")
      end
    end
    options
  end

  private def self.parse_tls_verify(value : String?) : Bool
    case value
    when nil, "true", "1" then true
    when "false", "0"     then false
    else                       raise ArgumentError.new("tls_verify must be true or false")
    end
  end

  private def self.parse_compression(value : String?) : Symbol
    case value
    when nil, "none" then :none
    when "lz4"       then :lz4
    else                  raise ArgumentError.new("unsupported compression")
    end
  end

  private def self.parse_database(path : String) : String
    return "default" if path.empty? || path == "/"
    URI.decode(path[1..])
  end

  def inspect(io : IO) : Nil
    io << "#<ClickHouse::Config host=" << @host << " port=" << @port << " database=" << @database
    io << " username=" << @username << " password=[REDACTED] tls=" << @tls << ">"
  end

  def to_s(io : IO) : Nil
    inspect(io)
  end
end
