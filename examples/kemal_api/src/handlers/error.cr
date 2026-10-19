require "./base"

class KemalAPI::Handlers::Error
  def initialize(@status : Int32)
  end

  def call(env : HTTP::Server::Context) : String
    env.response.content_type = "application/json"
    env.get?(Base::ERROR_BODY_KEY).as?(String) || {error: HTTP::Status.new(@status).description}.to_json
  end
end
