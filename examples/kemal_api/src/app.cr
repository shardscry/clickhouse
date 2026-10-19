require "./dependencies"
require "./routing"

@[ADI::Register(name: "app", public: true)]
class KemalAPI::App
  def initialize(@routing : KemalAPI::Routing)
  end

  def mount : Nil
    Kemal.config.max_request_body_size = KemalAPI::Handlers::Base::MAX_BODY_BYTES
    @routing.mount
  end
end
