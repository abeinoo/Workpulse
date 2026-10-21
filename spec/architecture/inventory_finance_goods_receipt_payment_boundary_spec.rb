require "rails_helper"

# Boundary for Batch S — Inventory & Purchasing → Finance & Sales goods-receipt
# payment writes (module-boundaries.md §14.2 #6, write half;
# docs/architecture/inventory-finance-goods-receipt-payments-baseline-failures.txt).
#
# A goods receipt's lifecycle, row lock, audits and advance-allocation arithmetic
# are Inventory & Purchasing's; the settlement and custody ledgers are Finance &
# Sales'. Since Batch S M4 the four goods-receipt services (and the allocator's
# apply!) reach them only through the Inventory contract
# Inventory::GoodsReceiptPaymentEffects, implemented by Finance & Sales
# (Finance::GoodsReceiptPaymentEffects) and wired in
# config/initializers/goods_receipt_payment_effects.rb.
#
# Rules:
# 1. No Inventory & Purchasing code writes the Finance & Sales ledgers, except the
#    Purchase Request advance deposit / reversal workflow — deferred to S2, frozen
#    here so it is neither widened nor silently migrated.
# 2. The migrated services name nothing from Finance & Sales; they call the
#    contract with exactly the classified operations, and nothing else in
#    Inventory & Purchasing calls it.
# 3. Every other Finance & Sales reference in Inventory & Purchasing code is a
#    classified read, frozen per file (a new one fails until classified).
# 4. The contract names nothing from Finance & Sales; the implementation never
#    drives the Inventory lifecycle; only the composition root names it, and it is
#    the registered handler.
module ArchitectureSpecs
  module InventoryFinanceGoodsReceiptPaymentBoundary
    module_function

    CONTRACT_FILE    = "app/services/inventory/goods_receipt_payment_effects.rb".freeze
    IMPLEMENTATION   = "app/services/finance/goods_receipt_payment_effects.rb".freeze
    COMPOSITION_ROOT = "config/initializers/goods_receipt_payment_effects.rb".freeze
    S2_WORKFLOW      = "app/services/inventory/purchase_request_advance_workflow.rb".freeze

    IP_MODELS = %w[
      goods_receipt goods_receipt_item inventory_movement laundry_batch laundry_batch_consumption
      laundry_standard_cost_rate product product_barcode product_warehouse_setting purchase_request
      purchase_request_advance purchase_request_item stock_adjustment stock_adjustment_item stock_count
      stock_count_item stock_issue stock_issue_import_batch stock_issue_import_row stock_issue_item stock_transfer
      stock_transfer_item towel_adjustment towel_ledger_entry towel_transfer towel_transfer_item towel_type warehouse
      warehouse_assignment warehouse_branch_supply
    ].freeze
    IP_POLICIES = %w[
      goods_receipt laundry_batch laundry_standard_cost_rate product_category product purchase_request_advance
      purchase_request stock_adjustment stock_count stock_issue stock_transfer supplier towel_adjustment towel_transfer
      towel_type warehouse_branch_supply warehouse
    ].freeze

    # Inventory & Purchasing code (module-boundaries.md §7, §10).
    IP_GLOBS = (%w[
      app/services/inventory/**/*.rb app/services/laundry/**/*.rb app/controllers/inventory/**/*.rb
      app/controllers/laundry/**/*.rb app/views/inventory/**/*.erb app/views/laundry/**/*.erb
      app/helpers/inventory_helper.rb
    ] + IP_MODELS.map { "app/models/#{_1}.rb" } + IP_POLICIES.map { "app/policies/#{_1}_policy.rb" }).freeze

    # The services migrated in Batch S M4 → the contract operations each calls.
    MIGRATED = {
      "app/services/inventory/goods_receipt_approval.rb"             => %w[approval_payment custody_account_active?],
      "app/services/inventory/purchase_request_advance_allocator.rb" => %w[advance_applied],
      "app/services/inventory/goods_receipt_settlement_recorder.rb"  => %w[payer_custody_account_id payment_source_kind? record_settlement],
      "app/services/inventory/goods_receipt_settlement_reverser.rb"  => %w[reverse_settlement],
      "app/services/inventory/goods_receipt_voider.rb"               => %w[reverse_all]
    }.freeze

    # A reference to the Finance & Sales payment ledgers (constants, custody
    # associations, the balance refresh, the implementation).
    FS_REF = /
      \bFinancialSettlement(?:Service)?\b | \bCustody(?:Account|Transaction)(?:Policy)?\b
      | \bFinance::(?:CustodyBalance|GoodsReceiptPaymentEffects)\b
      | \.custody_transactions\b | \.custody_accounts\b | \brefresh_balance!
    /x

    # A write to those ledgers.
    FS_WRITE = /
      \bFinancialSettlementService\b | \bFinancialSettlement\.(?:create|new)\b | \bCustodyTransaction\.(?:create|new)\b
      | \.custody_transactions\.(?:create|build|new)\b | \brefresh_balance!
    /x

    # Rule 3: the classified reads (Settleable / funding constants and associations
    # on the models, the receiving / settlement screens' account previews, the draft's
    # funding default) and the S2 workflow — file → reference lines.
    CLASSIFIED_REFS = {
      "app/controllers/inventory/goods_receipt_settlements_controller.rb" => 2, # own custody account + balance preview
      "app/controllers/inventory/goods_receipts_controller.rb"            => 2, # settlement list preload, own-account default
      "app/controllers/inventory/purchase_request_advances_controller.rb" => 1, # custody balances on the advance form (S2 screen)
      "app/controllers/inventory/purchase_requests_controller.rb"         => 1, # advance applications on the request page
      "app/models/goods_receipt.rb"                                       => 2, # FUNDING_SOURCE_TYPES, ACCOUNTLESS kinds
      "app/models/purchase_request.rb"                                    => 4, # advance / payment totals (Settleable reads)
      "app/models/purchase_request_advance.rb"                            => 1, # SOURCE_KINDS
      "app/services/inventory/custody_payment_preview.rb"                 => 1, # receiving-screen preview
      "app/services/inventory/goods_receipt_draft_service.rb"             => 1, # the draft's own-custody funding default
      "app/services/inventory/purchase_request_advance_recorder.rb"       => 2, # S2: advance custody account choice
      S2_WORKFLOW                                                         => 7, # S2: advance deposit / reversal writes
      "app/views/inventory/goods_receipt_settlements/new.html.erb"        => 1, # payment source options
      "app/views/inventory/goods_receipts/show.html.erb"                  => 2  # custody payment display
    }.freeze
    S2_WRITE_LINES = 6

    CONTRACT_CALL = /Inventory::GoodsReceiptPaymentEffects\.(\w+[?!]?)/

    # Driving the Inventory lifecycle from the implementation.
    INVENTORY_LIFECYCLE = /
      \bInventory::(?!GoodsReceiptPaymentEffects\b)\w+ | \bapproval_status\s*=(?!=) | \.update!?\(\s*approval_status:
      | \.(?:voided_at|status)\s*=(?!=) | \blog_audit\b | \binventory_movements\b
    /x

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    def ip_files
      IP_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }.map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end

    # Code only: full-line comments and ERB comments dropped, string contents
    # blanked, trailing comments removed.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""').sub(/\s#\s.*$/, ""), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def operations_called_in(path) = code_lines(path).flat_map { |line, _| line.scan(CONTRACT_CALL).flatten }.uniq.sort
  end
end

RSpec.describe "Architecture: Inventory & Purchasing reaches the goods-receipt payment ledgers only through Inventory::GoodsReceiptPaymentEffects" do
  boundary = ArchitectureSpecs::InventoryFinanceGoodsReceiptPaymentBoundary

  it "covers every Inventory & Purchasing glob (no stale glob or file)" do
    empty = boundary::IP_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
    expect(boundary::MIGRATED.keys + boundary::CLASSIFIED_REFS.keys - boundary.ip_files).to be_empty
  end

  it "no Inventory & Purchasing code writes the Finance & Sales ledgers outside the S2 workflow (rule 1)" do
    writes = boundary.ip_files.flat_map { |path| boundary.matches_in(path, boundary::FS_WRITE) }
    expect(writes.map { _1.split(":").first }.uniq).to eq([ boundary::S2_WORKFLOW ]), <<~MSG
      Write the settlement / custody ledgers through Inventory::GoodsReceiptPaymentEffects:
      #{writes.reject { _1.start_with?(boundary::S2_WORKFLOW) }.join("\n")}
    MSG
    expect(writes.size).to eq(boundary::S2_WRITE_LINES)
  end

  it "the S2 advance workflow is untouched by Batch S: it still writes directly and does not use the contract" do
    expect(boundary.matches_in(boundary::S2_WORKFLOW, /FinancialSettlementService\.(?:create|reverse)\b/).size).to eq(2)
    expect(boundary.operations_called_in(boundary::S2_WORKFLOW)).to be_empty
    expect(boundary.operations_called_in("app/services/inventory/purchase_request_advance_recorder.rb")).to be_empty
  end

  it "the migrated services name nothing from Finance & Sales (rule 2)" do
    named = boundary::MIGRATED.keys.flat_map { |path| boundary.matches_in(path, boundary::FS_REF) }
    expect(named).to be_empty, "Use the contract:\n#{named.join("\n")}"
  end

  it "the migrated services call exactly their classified operations, and nothing else in Inventory calls the contract (rule 2)" do
    callers = boundary.ip_files.to_h { |path| [ path, boundary.operations_called_in(path) ] }.reject { _2.empty? }
    callers.delete(boundary::CONTRACT_FILE)
    expect(callers).to eq(boundary::MIGRATED)
  end

  it "every other Finance & Sales reference in Inventory & Purchasing is a classified read, frozen per file (rule 3)" do
    refs = boundary.ip_files.to_h { |path| [ path, boundary.matches_in(path, boundary::FS_REF).size ] }.reject { _2.zero? }
    expect(refs).to eq(boundary::CLASSIFIED_REFS)
  end

  it "the contract names nothing from Finance & Sales (rule 4)" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::FS_REF)).to be_empty
    expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bFinance\b/)).to be_empty
  end

  it "the implementation never drives the Inventory lifecycle (rule 4)" do
    expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::INVENTORY_LIFECYCLE)).to be_empty
  end

  it "only the composition root and Finance & Sales name the implementation; it is the registered handler (rule 4)" do
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { |file| [ boundary::IMPLEMENTATION, boundary::COMPOSITION_ROOT ].include?(file) }
              .flat_map { |file| boundary.matches_in(file, /\bFinance::GoodsReceiptPaymentEffects\b/) }
    expect(outside).to be_empty, "Unexpected reference to the implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /Inventory::GoodsReceiptPaymentEffects\.register\(Finance::GoodsReceiptPaymentEffects\)/)).to be_present
    expect(Inventory::GoodsReceiptPaymentEffects.handler).to equal(Finance::GoodsReceiptPaymentEffects)
  end

  describe "self-tests" do
    def plant(path, content)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches each former direct write planted back into a migrated service" do
      [
        "FinancialSettlementService.create(settleable: receipt, amount: a, actor: u)",
        "FinancialSettlementService.reverse(settlement: s, actor: u)",
        "FinancialSettlementService.reverse_all(settleable: r, actor: u)",
        "account.custody_transactions.create!(txn_type: t, amount: -a)",
        "account.refresh_balance!",
        "CustodyTransaction.create!(custody_account: a)"
      ].each { |code| expect(code).to match(boundary::FS_WRITE), code }

      path = "app/services/inventory/goods_receipt_voider.rb"
      plant(path, "account.custody_transactions.create!(txn_type: t)\nInventory::GoodsReceiptPaymentEffects.reverse_all(receipt: r)\n")
      expect(boundary.matches_in(path, boundary::FS_WRITE)).not_to be_empty
    end

    it "catches a Finance & Sales read planted in a migrated service and a changed operation set" do
      path = "app/services/inventory/goods_receipt_approval.rb"
      plant(path, "account.is_a?(CustodyAccount) && account.active?\nInventory::GoodsReceiptPaymentEffects.approval_payment(receipt: r)\n")

      expect(boundary.matches_in(path, boundary::FS_REF)).not_to be_empty
      expect(boundary.operations_called_in(path)).not_to eq(boundary::MIGRATED[path])
    end

    it "does not match the contract, the association read retained in Inventory, i18n keys or comments" do
      plant("app/services/inventory/goods_receipt_settlement_reverser.rb",
            "# FinancialSettlementService.reverse in a comment\nreceipt.financial_settlements.advance_applications\n" \
            "I18n.t(\"financial_settlements.errors.already_reversed\")\n" \
            "Inventory::GoodsReceiptPaymentEffects.reverse_settlement(receipt: r, settlement_id: 1, actor: u, reason: x)\n")
      expect(boundary.matches_in("app/services/inventory/goods_receipt_settlement_reverser.rb", boundary::FS_REF)).to be_empty
    end

    it "catches the implementation driving the Inventory lifecycle" do
      plant(boundary::IMPLEMENTATION, "receipt.update!(approval_status: \"cancelled\")\nInventory::GoodsReceiptVoider.new(x).call\n")
      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::INVENTORY_LIFECYCLE).size).to eq(2)
    end
  end
end
