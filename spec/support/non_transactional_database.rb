# For single-connection examples that must observe a real COMMIT (BUG-003's
# production commit path), which the transactional fixture hides: inside it a
# service transaction is only a savepoint. Same guard as the two-connection
# concurrency specs (e.g. spec/services/inventory/document_voider_concurrency_spec.rb):
# refuses to start unless the test database is empty, and truncates every data
# table afterwards. No threads, so no worker connection can stay checked out.
#
#   include_context "non-transactional database"
RSpec.shared_context "non-transactional database" do
  self.use_transactional_tests = false

  def non_transactional_data_tables(conn) = conn.tables - %w[schema_migrations ar_internal_metadata]

  before do
    @non_transactional_guard_passed = false
    conn  = ActiveRecord::Base.connection
    dirty = non_transactional_data_tables(conn).select do |table|
      conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})")
    end
    raise "test database not empty (#{dirty.first(5).join(', ')}…): refusing to run a truncating spec" if dirty.any?

    @non_transactional_guard_passed = true
  end

  after do
    next unless @non_transactional_guard_passed

    conn = ActiveRecord::Base.connection
    raise "a transaction is still open after the example — truncation skipped" if conn.transaction_open?

    conn.truncate_tables(*non_transactional_data_tables(conn))
  end
end
