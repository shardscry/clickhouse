module ClickHouse
  VERSION           = "0.0.1-draft"
  VERSION_PARTS     = VERSION.split('-', 2).first.split('.').map(&.to_i)
  PROTOCOL_REVISION = 54460
  MINIMUM_REVISION  = 54459
end
