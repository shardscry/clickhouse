require "./config"

module KemalAPI::Schema
  def self.create(config : KemalAPI::Config) : Nil
    client = config.open_client
    begin
      client.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS #{config.quoted_table} (
          ingestion_id UUID,
          request_id String,
          received_at DateTime64(3, 'UTC'),
          impression_count UInt16,
          payload String
        ) ENGINE=MergeTree
        PARTITION BY toYYYYMM(received_at)
        ORDER BY (received_at, ingestion_id)
        SQL
    ensure
      client.close
    end
  end
end
