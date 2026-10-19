require "./version"

class ClickHouse::Error < Exception
end

class ClickHouse::ProtocolError < ClickHouse::Error
end

class ClickHouse::ConnectionError < ClickHouse::Error
end

class ClickHouse::ClosedError < ClickHouse::ConnectionError
end

class ClickHouse::BusyError < ClickHouse::Error
end

class ClickHouse::QueryTimeoutError < ClickHouse::ConnectionError
end

class ClickHouse::InsertOutcomeUnknown < ClickHouse::ConnectionError
  getter query_id : String

  def initialize(@query_id : String, cause : Exception? = nil)
    super("INSERT outcome is unknown (query_id=#{@query_id}); the operation was not retried", cause: cause)
  end
end

class ClickHouse::ServerError < ClickHouse::Error
  getter code : Int32
  getter name : String
  getter server_stack : String
  getter query_id : String?

  def initialize(@code : Int32, @name : String, message : String, @server_stack : String = "", @query_id : String? = nil)
    super("#{name} (#{code}): #{message}")
  end
end
