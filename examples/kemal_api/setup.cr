require "./src/schema"

config = KemalAPI::Config.new
KemalAPI::Schema.create(config)
puts "Table ready: #{config.quoted_table}"
