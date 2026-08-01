require "rails_helper"

RSpec.describe Finance::PosImports::Importer do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  before do
    create(:pos_terminal, business: business, branch: branch_a, terminal_id: "TERM-A")
    create(:pos_terminal, business: business, branch: branch_b, terminal_id: "TERM-B")
  end

  def headers
    [ "Transaction ID", "Order ID", "Gross Amount", "Payment Method", "Status",
      "Created At", "Paid At", "Fees", "Administrative Fees", "Product / Order Name",
      "Terminal ID", "Terminal Branch Name", "Branch ID", "Branch Name" ]
  end

  def data_row(transaction_id:, amount:, terminal_id:, status: "Success", fees: 0, administrative_fees: 0,
               paid_at: "2026-07-01 09:05:00")
    [ transaction_id, "ORD-#{transaction_id}", amount, "Card", status, "2026-07-01 09:00:00", paid_at,
      fees, administrative_fees, "Service", terminal_id, "Ignored Terminal Branch", "999", "Ignored Branch Name" ]
  end

  # Six preamble rows before the header — mirrors the provider report's header
  # landing around row 7, and proves HeaderDetector isn't relying on a
  # hardcoded row number.
  def pos_import_with_rows(rows)
    pos_import = create(:pos_import, business: business, imported_by: actor, status: "pending")
    bytes = XlsxBuilder.build([ [ "Some Company Inc." ], [], [], [], [], [], headers ] + rows)
    pos_import.file.attach(io: StringIO.new(bytes), filename: "export.xlsx")
    pos_import
  end

  it "imports valid rows and generates one expense per branch with fees" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", fees: "5.00", administrative_fees: "2.00"),
      data_row(transaction_id: "TXN-2", amount: "50.00",  terminal_id: "TERM-B", fees: "1.00", administrative_fees: "0.00")
    ])

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).to be_ok
    expect(PosTransaction.where(pos_import: pos_import).count).to eq(2)
    expect(pos_import.reload.status).to eq("imported")
    expect(pos_import.imported_rows).to eq(2)
    expect(pos_import.total_amount).to eq(150)
    expect(pos_import.total_fees).to eq(8)
    expect(pos_import.expenses_created_count).to eq(2)
    expect(Expense.where(source_pos_import: pos_import).count).to eq(2)
  end

  it "stores the provider's exact status string (not normalized) for an imported row" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "SUCCESS")
    ])

    described_class.call(pos_import.id, actor: actor)

    expect(PosTransaction.find_by(transaction_id: "TXN-1").status).to eq("SUCCESS")
  end

  describe "non-Success rows (Status filtering)" do
    it "does not create a PosTransaction for a Failed row" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Failed")
      ])

      result = described_class.call(pos_import.id, actor: actor)

      expect(result).to be_ok
      expect(PosTransaction.count).to eq(0)
      expect(pos_import.reload.imported_rows).to eq(0)
    end

    %w[Declined Cancelled Reversed].each do |status|
      it "ignores a #{status} row the same way" do
        pos_import = pos_import_with_rows([
          data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: status)
        ])

        described_class.call(pos_import.id, actor: actor)

        expect(PosTransaction.count).to eq(0)
      end
    end

    it "does not require Paid At for an ignored row — succeeds even with a blank date" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Failed", paid_at: "")
      ])

      result = described_class.call(pos_import.id, actor: actor)

      expect(result).to be_ok
      expect(pos_import.reload.invalid_rows).to eq(0)
    end

    it "does not count an ignored row's amount/fees toward totals" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Success", fees: "5.00"),
        data_row(transaction_id: "TXN-2", amount: "999.00", terminal_id: "TERM-A", status: "Failed", fees: "50.00")
      ])

      described_class.call(pos_import.id, actor: actor)

      expect(pos_import.reload.total_amount).to eq(100)
      expect(pos_import.total_fees).to eq(5)
    end

    it "does not generate an Expense from an ignored row's fees" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Failed", fees: "50.00")
      ])

      described_class.call(pos_import.id, actor: actor)

      expect(Expense.where(source_pos_import: pos_import).count).to eq(0)
    end

    it "records ignored_rows count and ignored_amount, without appearing in invalid_rows" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", status: "Success"),
        data_row(transaction_id: "TXN-2", amount: "30.00",  terminal_id: "TERM-A", status: "Failed"),
        data_row(transaction_id: "TXN-3", amount: "20.00",  terminal_id: "TERM-A", status: "Declined")
      ])

      described_class.call(pos_import.id, actor: actor)
      pos_import.reload

      expect(pos_import.ignored_rows).to eq(2)
      expect(pos_import.ignored_amount).to eq(50)
      expect(pos_import.invalid_rows).to eq(0)
    end
  end

  it "imports nothing when any Terminal ID is unknown" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "TXN-2", amount: "50.00",  terminal_id: "GHOST-TERMINAL")
    ])

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).not_to be_ok
    expect(result.error).to include("GHOST-TERMINAL")
    expect(PosTransaction.count).to eq(0)
    expect(pos_import.reload.status).to eq("pending")
  end

  it "imports successfully once the single row with an unknown terminal is ignored" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "TXN-2", amount: "50.00",  terminal_id: "GHOST-TERMINAL")
    ])
    unknown_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                      .resolution.unknown_terminals.first[:row_number]
    Finance::PosImports::RowIgnorer.call(pos_import.id, row_number: unknown_row_number,
                                        reason: "Bad terminal on this row only", actor: actor)

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).to be_ok
    expect(PosTransaction.count).to eq(1)
    expect(pos_import.reload.imported_rows).to eq(1)
  end

  it "skips a duplicate transaction_id and counts it, without creating a second row" do
    create(:pos_transaction, business: business, branch: branch_a, transaction_id: "TXN-1")
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "999.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "TXN-2", amount: "50.00",  terminal_id: "TERM-A")
    ])

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).to be_ok
    expect(pos_import.reload.duplicate_rows).to eq(1)
    expect(pos_import.imported_rows).to eq(1)
    expect(PosTransaction.where(transaction_id: "TXN-1").count).to eq(1)
  end

  it "treats duplicate transaction_ids within the same file as duplicates too" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A")
    ])

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).to be_ok
    expect(pos_import.reload.duplicate_rows).to eq(1)
    expect(PosTransaction.where(transaction_id: "TXN-1").count).to eq(1)
  end

  describe "row-level validation errors (hard gate)" do
    it "blocks the entire import while any row-level validation error remains" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
        data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
      ])

      result = described_class.call(pos_import.id, actor: actor)

      expect(result).not_to be_ok
      expect(result.error).to include("still have validation errors")
      expect(PosTransaction.count).to eq(0)
      expect(pos_import.reload.status).to eq("pending")
    end

    it "imports successfully once the offending row is explicitly ignored" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A"),
        data_row(transaction_id: "", amount: "50.00", terminal_id: "TERM-A")
      ])
      invalid_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                        .validation.invalid_rows.first[:row_number]
      Finance::PosImports::RowIgnorer.call(pos_import.id, row_number: invalid_row_number,
                                          reason: "Corrupted export row", actor: actor)

      result = described_class.call(pos_import.id, actor: actor)

      expect(result).to be_ok
      expect(PosTransaction.count).to eq(1)
      expect(pos_import.reload.imported_rows).to eq(1)
      expect(pos_import.invalid_rows).to eq(0)
    end

    it "does not count an ignored row toward totals, fees, or expense generation" do
      pos_import = pos_import_with_rows([
        data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", fees: "5.00"),
        data_row(transaction_id: "", amount: "999.00", terminal_id: "TERM-A", fees: "50.00")
      ])
      invalid_row_number = Finance::PosImports::Pipeline.call(pos_import, business: business)
                                                        .validation.invalid_rows.first[:row_number]
      Finance::PosImports::RowIgnorer.call(pos_import.id, row_number: invalid_row_number,
                                          reason: "Bad row", actor: actor)

      described_class.call(pos_import.id, actor: actor)
      pos_import.reload

      expect(pos_import.total_amount).to eq(100)
      expect(pos_import.total_fees).to eq(5)
      expect(Expense.where(source_pos_import: pos_import).sum(:amount)).to eq(5)
    end
  end

  it "rolls back everything, including already-persisted transactions, when a fatal error occurs" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", fees: "5.00")
    ])

    allow(Finance::PosImports::ExpenseGenerator).to receive(:call)
      .and_return(Finance::PosImports::ExpenseGenerator::Result.new(ok: false, reason: "boom"))

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).not_to be_ok
    expect(result.error).to eq("boom")
    expect(PosTransaction.count).to eq(0)
    expect(pos_import.reload.status).to eq("failed")
  end

  it "errors cleanly when re-confirming an already-imported record" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A")
    ])
    described_class.call(pos_import.id, actor: actor)

    result = described_class.call(pos_import.id, actor: actor)

    expect(result).not_to be_ok
    expect(PosTransaction.where(pos_import: pos_import).count).to eq(1)
  end

  # Regression for a data-loss bug: when the source XLSX has "Paid At"
  # formatted as a real Excel datetime cell (not plain text), Roo returns a
  # Ruby DateTime for it. ExcelReader#cell_to_s previously matched DateTime
  # against its date-ONLY branch (DateTime < Date, and the case order was
  # `when Date, DateTime`), silently truncating every such row's Paid At to
  # midnight. See excel_reader_spec.rb for the isolated ExcelReader-level
  # version of this regression.
  #
  # POS Transaction Verification also no longer buckets by business day at
  # all (PosTransaction.for_calendar_date, not .for_business_day) — POS
  # transactions are external financial records reconciled against their
  # actual Paid At calendar date, never shifted by business_day_start_hour.
  # This spec asserts BOTH: the time-of-day survives the real-Excel-cell
  # round trip, and business_day_start_hour has zero effect on which
  # calendar date a transaction lands on.
  describe "real Excel-typed 'Paid At' datetime cells (calendar-date bucketing)" do
    let(:business) { create(:business, business_day_start_hour: 9) }

    it "keeps both an early (08:00) and a late (10:00) same-day transaction on their shared calendar date, ignoring business_day_start_hour" do
      pos_import = create(:pos_import, business: business, imported_by: actor, status: "pending")
      rows = [
        data_row(transaction_id: "TXN-EARLY", amount: "1000.00", terminal_id: "TERM-A",
                 paid_at: XlsxBuilder::ExcelDateTime.new(Time.utc(2026, 7, 12, 8, 0, 0))),
        data_row(transaction_id: "TXN-LATE", amount: "2000.00", terminal_id: "TERM-A",
                 paid_at: XlsxBuilder::ExcelDateTime.new(Time.utc(2026, 7, 12, 10, 0, 0)))
      ]
      bytes = XlsxBuilder.build([ [ "Some Company Inc." ], [], [], [], [], [], headers ] + rows)
      pos_import.file.attach(io: StringIO.new(bytes), filename: "export.xlsx")

      # Real imports always run inside a signed-in controller request, which
      # ApplicationController#set_business_timezone wraps in
      # Time.use_zone(business.timezone_object) — reproduce that here so
      # Importer#parse_time (Time.zone.parse) interprets the naive "Paid At"
      # string the same way production does, instead of under the test
      # environment's default UTC.
      result = Time.use_zone(business.timezone_object) { described_class.call(pos_import.id, actor: actor) }
      expect(result).to be_ok

      same_day     = PosTransaction.for_calendar_date(branch: branch_a, date: Date.new(2026, 7, 12), business: business)
      previous_day = PosTransaction.for_calendar_date(branch: branch_a, date: Date.new(2026, 7, 11), business: business)

      expect(same_day.pluck(:transaction_id)).to contain_exactly("TXN-EARLY", "TXN-LATE")
      expect(same_day.sum(:amount)).to eq(3000)
      expect(previous_day).to be_empty
    end

    it "produces an identical stored transaction_date for a real Excel datetime cell and an equivalent plain-text cell — no timezone conversion introduced anywhere in the pipeline" do
      typed_import = create(:pos_import, business: business, imported_by: actor, status: "pending")
      typed_rows = [ data_row(transaction_id: "TXN-TYPED", amount: "500.00", terminal_id: "TERM-A",
                              paid_at: XlsxBuilder::ExcelDateTime.new(Time.utc(2026, 7, 12, 14, 35, 0))) ]
      typed_import.file.attach(io: StringIO.new(XlsxBuilder.build([ [ "Some Company Inc." ], [], [], [], [], [], headers ] + typed_rows)), filename: "typed.xlsx")

      text_import = create(:pos_import, business: business, imported_by: actor, status: "pending")
      text_rows = [ data_row(transaction_id: "TXN-TEXT", amount: "500.00", terminal_id: "TERM-A",
                             paid_at: "2026-07-12 14:35:00") ]
      text_import.file.attach(io: StringIO.new(XlsxBuilder.build([ [ "Some Company Inc." ], [], [], [], [], [], headers ] + text_rows)), filename: "text.xlsx")

      Time.use_zone(business.timezone_object) do
        expect(described_class.call(typed_import.id, actor: actor)).to be_ok
        expect(described_class.call(text_import.id, actor: actor)).to be_ok
      end

      typed_txn = PosTransaction.find_by(transaction_id: "TXN-TYPED")
      text_txn  = PosTransaction.find_by(transaction_id: "TXN-TEXT")

      expect(typed_txn.transaction_date).to eq(text_txn.transaction_date)
      # The stored instant, re-expressed in the business's own timezone,
      # must read back as the EXACT "Paid At" wall-clock value from the
      # source file — proving nothing shifted it along the way.
      expect(typed_txn.transaction_date.in_time_zone(business.timezone_object).strftime("%Y-%m-%d %H:%M:%S"))
        .to eq("2026-07-12 14:35:00")
    end
  end

  it "creates no expense for a branch whose imported rows have zero fees" do
    pos_import = pos_import_with_rows([
      data_row(transaction_id: "TXN-1", amount: "100.00", terminal_id: "TERM-A", fees: "0", administrative_fees: "0")
    ])

    described_class.call(pos_import.id, actor: actor)

    expect(Expense.where(source_pos_import: pos_import).count).to eq(0)
  end
end
