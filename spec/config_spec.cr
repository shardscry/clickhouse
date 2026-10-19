require "spec"
require "../src/clickhouse/config"

describe ClickHouse::Config do
  it "parses credentials, database, IPv6, and TLS without changing plus signs" do
    config = ClickHouse::Config.from_string("clickhouses://some%2Buser:p%40ss@[::1]/data%20set?compression=lz4")
    config.host.should eq("::1")
    config.port.should eq(9440)
    config.username.should eq("some+user")
    config.password.should eq("p@ss")
    config.database.should eq("data set")
    config.tls?.should be_true
    config.tls_verify?.should be_true
    config.compression.should eq(:lz4)
    config.inspect.should_not contain("p@ss")
  end

  it "rejects invalid options and unsafe numeric configuration" do
    expect_raises(ArgumentError) { ClickHouse::Config.from_string("http://localhost") }
    expect_raises(ArgumentError) { ClickHouse::Config.from_string("clickhouse://localhost?tls_verify=maybe") }
    expect_raises(ArgumentError) { ClickHouse::Config.new(batch_size: 0) }
    expect_raises(ArgumentError) { ClickHouse::Config.new(query_timeout: 0.seconds) }
  end

  it "rejects unknown URI options instead of silently accepting misspelled configuration" do
    expect_raises(ArgumentError, /unsupported connection option read_timout/) do
      ClickHouse::Config.from_string("clickhouse://localhost?read_timout=5")
    end
  end

  it "gives explicit TLS and resource options priority over URI values and defaults" do
    config = ClickHouse::Config.from_string(
      "clickhouses://name+tag:pass+word%252F@localhost/data+set?tls_ca=uri.pem&tls_hostname=uri-host&tls_verify=true&compression=lz4",
      tls_ca: "explicit.pem", tls_hostname: "explicit-host", tls_verify: false,
      compression: :none, port: 19440, max_result_bytes: 1024,
    )
    config.tls_ca.should eq("explicit.pem")
    config.tls_hostname.should eq("explicit-host")
    config.tls_verify?.should be_false
    config.compression.should eq(:none)
    config.port.should eq(19440)
    config.max_result_bytes.should eq(1024)
    config.username.should eq("name+tag")
    config.password.should eq("pass+word%2F")
    config.database.should eq("data+set")
  end
end
