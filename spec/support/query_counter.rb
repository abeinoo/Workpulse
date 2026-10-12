# Counts real SQL statements (excluding schema and query-cache hits) run by a
# block — for specs that pin down N+1 fixes.
module QueryCounter
  def count_queries(&block)
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:name] == "SCHEMA" || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end

RSpec.configure { |config| config.include QueryCounter }
