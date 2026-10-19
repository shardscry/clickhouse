require "./handlers/bulk_bids"
require "./handlers/list_bids"
require "./handlers/error"

@[ADI::Register]
class KemalAPI::Routing
  def initialize(
    @bulk_bids : KemalAPI::Handlers::BulkBids,
    @list_bids : KemalAPI::Handlers::ListBids,
  )
  end

  def mount : Nil
    router = Kemal::Router.new
    router.post("/ortb/bids/bulk") { |env| @bulk_bids.call(env) }
    router.get("/ortb/bids") { |env| @list_bids.call(env) }
    router.register_routes

    {400, 404, 405, 413, 415, 422, 500, 503}.each do |status|
      handler = Handlers::Error.new(status)
      Kemal.config.add_error_handler(status) { |env, _error| handler.call(env) }
    end
  end
end
