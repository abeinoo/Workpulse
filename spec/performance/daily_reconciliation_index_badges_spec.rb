require "rails_helper"

# Regression guard for the Daily Reconciliation index's issue badges after
# the performance pass: one narrow Sales Transaction load shared by both
# badge builders, and badge figures identical to the original logic (the
# frozen original Comparator — spec/support/legacy_pos_comparator.rb — over
# fully loaded rows, exactly as the badge builders used to compute them).
RSpec.describe "Daily Reconciliation index — issue badge loading", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let!(:card_pm) { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true, include_in_pos_verification: true) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                             permission_scopes: perms.index_with { "business_wide" })
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer) do
    user_with("view_daily_reconciliation", "view_deposit_verification", "view_sales_transactions_verification",
              "view_pos_import", "view_all_employee_reconciliation_summary")
  end
  let(:cashiers) { [ create(:user, business: business, first_name: "Mona", last_name: "Fathy"),
                     create(:user, business: business, first_name: "Omar", last_name: "Saeed") ] }
  let(:sales_import) { SalesImport.create!(business: business, imported_by: viewer, file_name: "s.csv", status: "imported") }
  let(:pos_import)   { create(:pos_import, business: business, imported_by: viewer) }

  # A mix that exercises every badge path: reference matches (case/space
  # variants), amount+time-window matches incl. ties, amount mismatches,
  # unmatched rows on both sides, a non-verification payment method, and
  # employee shortfalls.
  def seed!
    rng = Random.new(42)
    [ [ branch_a, 0 ], [ branch_a, 1 ], [ branch_b, 0 ], [ branch_b, 2 ] ].each_with_index do |(branch, days_ago), n|
      date = Date.current - days_ago
      dr = DailyReconciliation.create!(branch: branch, business: business, state: "closed", business_date: date,
                                       opened_at: date.to_time + 8.hours, closed_at: date.to_time + 22.hours)
      TillSession.create!(daily_reconciliation: dr, depositor_id: viewer.id)

      cashiers.each_with_index do |cashier, i|
        close = TillHandover.create!(daily_reconciliation: dr, from_user: cashier, self_deposit: true, accepted_at: Time.current)
        TillHandoverAmount.create!(till_handover: close, payment_method: card_pm, payment_method_name: "Card",
                                   collected_amount: 300 + (i * 50), refund_amount: 0, kind: "operational")
      end

      12.times do |k|
        amount = [ 100, 100, 150, 75.5, 200 ].sample(random: rng)
        at     = Time.zone.local(date.year, date.month, date.day, 12, 0, 0) + rng.rand(-900..900)
        ref    = [ nil, "R#{n}-#{k}", " r#{n}-#{k} " ].sample(random: rng)
        SalesTransaction.create!(
          business: business, sales_import: sales_import, daily_reconciliation: dr, transaction_date: date,
          transaction_time: rng.rand < 0.1 ? nil : at.strftime("%H:%M:%S"), cashier_name: cashiers.sample(random: rng).full_name.upcase,
          branch_name: branch.name, payment_method_name: rng.rand < 0.2 ? "Cash" : " card ", amount: amount, reference_number: ref,
          raw_data: { "note" => "x" * 200 }
        )
        next if rng.rand < 0.25

        PosTransaction.create!(
          pos_import: pos_import, business: business, branch: branch, transaction_id: "T#{n}-#{k}-#{SecureRandom.hex(3)}",
          amount: rng.rand < 0.15 ? amount + 1 : amount, status: "Success", terminal_id: "TERM",
          transaction_date: at + rng.rand(-400..400), reference_number: [ nil, "R#{n}-#{k}", "other" ].sample(random: rng)
        )
      end
    end
  end

  # The badge builders' original logic, verbatim apart from using the frozen
  # original Comparator and loading full rows, run independently of the
  # controller.
  def expected_badges(drs)
    pms = PaymentMethod.for_business(business).to_a
    pm_id_by_name = pms.each_with_object({}) { |pm, h| h[pm.name.downcase.strip] = pm.id }
    verification_ids = pms.select(&:include_in_pos_verification).map(&:id).to_set
    tz = business.timezone_object
    sales_by_dr = SalesTransaction.where(daily_reconciliation_id: drs.map(&:id)).group_by(&:daily_reconciliation_id)
    pos_by_branch_date = PosTransaction.where(business_id: business.id).to_a
                                       .group_by { |t| [ t.branch_id, t.transaction_date.in_time_zone(tz).to_date ] }

    pos_counts = {}
    sales_counts = {}
    drs.each do |dr|
      sales = (sales_by_dr[dr.id] || []).select do |txn|
        verification_ids.include?(pm_id_by_name[txn.payment_method_name.downcase.strip] || txn.payment_method_name)
      end
      pos = pos_by_branch_date[[ dr.branch_id, dr.business_date ]] || []
      next if sales.empty? && pos.empty?

      result = LegacyPosComparator::Comparator.call(sales, pos)
      unmatched_pos = result.extra_in_pos.size + result.matched_pairs.count(&:amount_mismatch?)
      pos_counts[dr.id] = unmatched_pos if unmatched_pos.positive?
      sales_counts[dr.id] = result.missing_from_pos.size if result.missing_from_pos.any?
    end

    employee = {}
    drs.each do |dr|
      rows = sales_by_dr[dr.id]
      next if rows.blank?

      totals = rows.group_by { |t| t.cashier_name.to_s.downcase.strip }.transform_values { |ts| ts.sum(&:amount) }
      issues = Finance::EmployeeReconciliationSummarizer.new(dr).summaries.filter_map do |summary|
        next unless summary.user

        diff = summary.grand_total.to_d - (totals[summary.user.full_name.downcase.strip] || 0)
        [ summary.user.id, diff.abs ] if diff.negative?
      end
      employee[dr.id] = issues if issues.any?
    end

    { pos: pos_counts, sales: sales_counts, employee: employee }
  end

  def actual_badges
    employee = controller.instance_variable_get(:@employee_sales_issues_by_dr)
                         .select { |_, v| v.any? }
                         .transform_values { |v| v.map { |i| [ i[:user].id, i[:amount] ] } }
    { pos: controller.instance_variable_get(:@pos_unmatched_count_by_dr),
      sales: controller.instance_variable_get(:@sales_unmatched_count_by_dr),
      employee: employee }
  end

  # Row-loading Sales Transaction queries, INCLUDING query-cache hits — a
  # repeated identical load used to be answered by the query cache and still
  # re-instantiated every row.
  def sales_row_loads
    loads = []
    counter = lambda do |*, payload|
      sql = payload[:sql]
      loads << sql if sql.include?('FROM "sales_transactions"') && !sql.include?("DISTINCT")
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    loads
  end

  before do
    seed!
    sign_in viewer
  end

  it "computes badge figures identical to the original badge logic" do
    Time.use_zone(business.timezone_object) do
      get finance_daily_reconciliations_path
      drs = controller.instance_variable_get(:@reconciliations)

      expected = expected_badges(drs)
      expect(actual_badges).to eq(expected)
      # Non-vacuous: the seeded data really produces every badge kind.
      expect(expected[:pos]).not_to be_empty
      expect(expected[:sales]).not_to be_empty
      expect(expected[:employee]).not_to be_empty
    end
  end

  it "loads Sales Transactions once for both badge builders, without raw_data" do
    get finance_daily_reconciliations_path # warm-up

    loads = sales_row_loads { get finance_daily_reconciliations_path }

    expect(loads.size).to eq(1)
    expect(loads.first).not_to include('"sales_transactions".*')
    expect(loads.first).not_to include("raw_data")
  end

  it "still loads Sales Transactions (once) for employee badges when the POS badges are gated off" do
    no_pos = user_with("view_daily_reconciliation", "view_deposit_verification",
                       "view_sales_transactions_verification", "view_all_employee_reconciliation_summary")
    sign_in no_pos

    loads = sales_row_loads { get finance_daily_reconciliations_path }

    expect(loads.size).to eq(1)
    expect(controller.instance_variable_get(:@pos_unmatched_count_by_dr)).to be_nil
    expect(controller.instance_variable_get(:@employee_sales_issues_by_dr).values.flatten).not_to be_empty
  end
end
