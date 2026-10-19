require "kemal"
require "clickhouse"
require "../errors/request_error"

private alias Context = HTTP::Server::Context
private alias RequestError = KemalAPI::Errors::RequestError

module KemalAPI::Handlers::Base
  MAX_BODY_BYTES = 16 * 1024 * 1024
  ERROR_BODY_KEY = "kemal_api.error_body"

  protected def respond(env : Context, & : -> String) : String
    env.response.content_type = "application/json"
    yield
  rescue ex : RequestError
    error_response(env, ex.status, {error: ex.message})
  rescue ex : ClickHouse::InsertOutcomeUnknown
    error_response(env, 503, {error: "insert outcome is unknown; verify the query before retrying", query_id: ex.query_id})
  rescue ClickHouse::ConnectionError
    error_response(env, 503, {error: "database is unavailable"})
  rescue ClickHouse::Error
    error_response(env, 500, {error: "database operation failed"})
  rescue Exception
    error_response(env, 500, {error: "internal server error"})
  end

  protected def error_response(env : Context, status : Int32, payload) : String
    env.response.status_code = status
    body = payload.to_json
    # Kemal dispatches custom status handlers after the route returns.
    env.set(ERROR_BODY_KEY, body)
    body
  end

  protected def read_json_body(env : Context) : String
    content_type = env.request.headers["Content-Type"]?.try(&.split(';', 2).first.strip.downcase)
    raise RequestError.new(415, "Content-Type must be application/json") unless content_type == "application/json"
    env.params.raw_body
  rescue Kemal::Exceptions::PayloadTooLarge
    raise RequestError.new(413, "body exceeds #{MAX_BODY_BYTES} bytes")
  end
end
