require "athena-dependency_injection"

module KemalAPI::Injectable
  macro inject(dependency)
    def initialize(@{{ dependency.var.id }} : {{ dependency.type }})
    end
  end
end
