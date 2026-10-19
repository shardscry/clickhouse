class KemalAPI::Errors::RequestError < Exception
  getter status : Int32

  def initialize(@status : Int32, message : String)
    super(message)
  end
end
