module Inventory
  module Packaging
    # Raised with a readable, translated message when packaging makes an
    # operation impossible (Planner::Refusal turned into text by
    # Format.refusal); posters turn it into a document error and roll back.
    class Refused < StandardError; end
  end
end
