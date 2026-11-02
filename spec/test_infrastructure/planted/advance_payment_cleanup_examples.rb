# BUG-024 — planted examples that run inside a REAL two-connection concurrency
# harness (spec/services/requests/advance_payment_concurrency_spec.rb), so its
# own guard, worker shutdown, ConcurrencyConnectionCheck and truncation are what
# get exercised — not a copy of them. Not a *_spec.rb file: the suite never runs
# it. Only spec/test_infrastructure/concurrency_cleanup_safety_spec.rb runs it,
# in a child rspec process (`--tag planted --order defined`), and asserts on the
# outcome. Two of these examples are expected to FAIL (their cleanup must refuse
# to truncate and say why).
return unless ENV["BUG024_PLANTED_CLEANUP"] == "1"

require "rails_helper"
require Rails.root.join("spec/services/requests/advance_payment_concurrency_spec.rb").to_s

module PlantedCleanupLog
  module_function

  def write(line)
    File.open(ENV.fetch("BUG024_PLANTED_LOG"), "a") { |f| f.puts(line) }
  end

  def data_counts
    conn = ActiveRecord::Base.connection
    (conn.tables - %w[schema_migrations ar_internal_metadata]).to_h do |table|
      [ table, conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(table)}").to_i ]
    end
  end

  # Records every truncation and the example it ran in.
  module TruncationSpy
    def truncate_tables(*table_names)
      PlantedCleanupLog.write("TRUNCATE #{RSpec.current_example&.metadata&.fetch(:planted)}")
      super
    end
  end
end
ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(PlantedCleanupLog::TruncationSpy)

harness = RSpec.world.example_groups.find do |group|
  group.metadata[:file_path].end_with?("spec/services/requests/advance_payment_concurrency_spec.rb")
end || raise("advance payment concurrency harness not loaded")

# Releases whatever a planted example left holding the database, so the next
# example starts clean — only once the harness's own `after` hook has run
# (whether or not it raised): an `around` hook wraps every before/after hook.
# (An `after` hook added here would run BEFORE the harness's: a filtered
# configuration hook added after the group exists is attached to it, and later
# after hooks run first.)
RSpec.configure do |config|
  config.around(:example, :planted) do |example|
    example.run
    PlantedCleanupLog.write("RELEASE #{example.metadata[:planted]}")
    @planted_release&.push(true)
    @planted_holder&.join(10)
    @planted_session&.close
  end
end

# A — a worker still inside a transaction (holding an uncommitted row) when the
# cleanup runs: the cleanup must report it and must not truncate.
harness.it "A1: a worker still using the database blocks truncation", planted: "A1" do
  inserted = Queue.new
  release  = @planted_release = Queue.new
  @planted_holder = Thread.new do
    Thread.current.name = "planted-active-worker"
    ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do
      ActiveRecord::Base.transaction do
        create(:business, name: "planted uncommitted business")
        inserted << true
        release.pop
        raise ActiveRecord::Rollback # never committed, released or not (a lost process rolls back too)
      end
    end
  end
  Timeout.timeout(10) { inserted.pop }
  PlantedCleanupLog.write("A1 holder started")
end

# A (continued) — once that worker was released (rolled back), the next
# example's guard finds the database empty and its own cleanup truncates.
harness.it "A2: after the worker is released, cleanup proceeds", planted: "A2" do
  create(:user, business: create(:business, name: "planted committed business"))
  PlantedCleanupLog.write("A2 committed #{PlantedCleanupLog.data_counts.values.sum} rows")
end

# C — the records A2 committed are gone: the guard passed (it raises on any
# row) and every data table is empty.
harness.it "C: the next example starts with every table empty", planted: "C" do
  non_empty = PlantedCleanupLog.data_counts.reject { |_, count| count.zero? }
  PlantedCleanupLog.write("C non-empty tables: #{non_empty.inspect}")
  expect(non_empty).to be_empty
end

# B — a database session that stays inside a transaction past the cleanup's
# wait: the cleanup must fail loudly, name the session and pool state, and not
# truncate.
harness.it "B: a persistent open session fails the cleanup loudly", planted: "B" do
  config = ActiveRecord::Base.connection_db_config.configuration_hash
  @planted_session = PG.connect(host: config[:host], port: config[:port], user: config[:username],
                                password: config[:password], dbname: config[:database])
  @planted_session.exec("BEGIN")
  @planted_session.exec("SELECT 1")
  PlantedCleanupLog.write("B session pid=#{@planted_session.backend_pid}")
end
