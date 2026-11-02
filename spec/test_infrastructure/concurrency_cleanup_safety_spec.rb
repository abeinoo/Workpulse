require "rails_helper"
require "open3"

# BUG-024 — the cleanup of a REAL two-connection concurrency harness
# (spec/services/requests/advance_payment_concurrency_spec.rb), driven through
# planted examples (spec/test_infrastructure/planted/advance_payment_cleanup_examples.rb)
# run in a child rspec process, in this order:
#
#   A1  a worker still inside a transaction when the cleanup runs → the cleanup
#       names the worker and its session, does not truncate, and fails
#   A2  that worker released → the next example's guard passes and its cleanup
#       truncates the rows it committed
#   C   the example after that finds every table empty
#   B   a session left inside a transaction past the cleanup's wait → the
#       cleanup fails loudly with pool and session state, and does not truncate
#
# A child process because a failing harness cleanup is the behaviour under
# test: it must fail its example, and that must not fail this run. Truncations
# and releases are logged by the planted file, so "did not truncate" is
# observed, not inferred.
#
# Not transactional: an open transaction here would itself be a session the
# child's cleanup (correctly) refuses to truncate around. Writes no rows; the
# child leaves the test database as empty as it found it.
RSpec.describe "Concurrency cleanup safety in a real harness (BUG-024)" do
  self.use_transactional_tests = false

  def child_timeout = 180 # seconds; the child normally takes ~15 s (boot + two 2 s cleanup waits)

  let(:planted_file) { "spec/test_infrastructure/planted/advance_payment_cleanup_examples.rb" }

  def non_empty_tables
    conn = ActiveRecord::Base.connection
    (conn.tables - %w[schema_migrations ar_internal_metadata]).select do |table|
      conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})")
    end
  end

  def run_planted(dir)
    log  = File.join(dir, "planted.log")
    json = File.join(dir, "result.json")
    output, status = Open3.popen2e(
      { "BUG024_PLANTED_CLEANUP" => "1", "BUG024_PLANTED_LOG" => log },
      "bundle", "exec", "rspec", planted_file, "--tag", "planted", "--order", "defined",
      "--format", "json", "--out", json, "--format", "progress",
      chdir: Rails.root.to_s, pgroup: true
    ) do |stdin, out, waiter|
      stdin.close
      reader = Thread.new { out.read }
      # Bounded: a hung child is killed (with its process group) and reported.
      unless waiter.join(child_timeout)
        Process.kill("KILL", -waiter.pid)
        raise "planted child rspec still running after #{child_timeout}s and was killed:\n#{reader.join(5) && reader.value}"
      end
      [ reader.value, waiter.value ]
    end
    examples = File.exist?(json) ? JSON.parse(File.read(json))["examples"] : []
    [ status, output, examples.to_h { |e| [ e["description"][/\A\w+/], e ] }, File.exist?(log) ? File.readlines(log, chomp: true) : [] ]
  end

  it "refuses to truncate around a live worker or open session, fails loudly, and otherwise leaves every table empty" do
    expect(non_empty_tables).to be_empty, -> { "test database not empty before the planted run: #{non_empty_tables.inspect}" }

    status, output, examples, log = Dir.mktmpdir("bug024-planted") { |dir| run_planted(dir) }
    explain = -> { "child rspec output:\n#{output}\nplanted log:\n#{log.join("\n")}" }

    expect(examples.keys).to eq(%w[A1 A2 C B]), explain
    expect(status.exitstatus).to eq(1), explain # the two cleanups that must fail did

    # A1 — reported the live worker and its open transaction; truncation not invoked.
    a1 = examples.fetch("A1")
    expect(a1["status"]).to eq("failed"), explain
    expect(a1.dig("exception", "message")).to include(
      "1 connection(s) still leased by other live thread(s)",
      "1 other database session(s) still active or in a transaction after waiting 2.0s",
      'name="planted-active-worker" alive=true',
      'state="idle in transaction"',
      'INSERT INTO \\"businesses\\"',
      "pool: size=",
      "truncation SKIPPED"
    )

    # A2 / C — after the release the guard passed, cleanup truncated, the next example found nothing.
    expect(examples.fetch("A2")["status"]).to eq("passed"), explain
    expect(examples.fetch("C")["status"]).to eq("passed"), explain
    expect(log).to include("C non-empty tables: {}")

    # B — a persistent session: actionable failure naming it; truncation not invoked.
    b   = examples.fetch("B")
    pid = log.grep(/\AB session pid=/).sole[/\d+/]
    expect(b["status"]).to eq("failed"), explain
    expect(b.dig("exception", "message")).to include(
      "1 other database session(s) still active or in a transaction after waiting 2.0s",
      %(postgres backend pid=#{pid} state="idle in transaction"),
      "pool: size=",
      "truncation SKIPPED"
    )
    expect(b.dig("exception", "message")).not_to include("pool connection leased by")

    # Truncation ran exactly in the examples whose cleanup found nothing in use,
    # and each release came only after that example's cleanup had decided.
    expect(log.grep(/\A(TRUNCATE|RELEASE) /)).to eq(
      [ "RELEASE A1", "TRUNCATE A2", "RELEASE A2", "TRUNCATE C", "RELEASE C", "RELEASE B" ]
    ), explain

    expect(non_empty_tables).to be_empty
  end
end
