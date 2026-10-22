require "rails_helper"

# Boundary for Inventory & Purchasing → Finance & Sales payment writes
# (module-boundaries.md §14.2 #6): Batch S (goods-receipt payments,
# docs/architecture/inventory-finance-goods-receipt-payments-baseline-failures.txt)
# and S2 (Purchase Request advance deposits / reversals,
# docs/architecture/inventory-finance-purchase-request-advances-baseline-failures.txt).
#
# A goods receipt's and an advance's lifecycle, row locks, audits and the advance
# arithmetic are Inventory & Purchasing's; the settlement and custody ledgers,
# custody accounts and custody visibility are Finance & Sales'. Inventory reaches
# them only through its two contracts, each implemented by Finance & Sales and
# wired in its own initializer:
#   Inventory::GoodsReceiptPaymentEffects   → Finance::GoodsReceiptPaymentEffects   (Batch S M4)
#   Inventory::PurchaseRequestAdvanceEffects → Finance::PurchaseRequestAdvanceEffects (S2)
#
# Rules:
# 1. No Inventory & Purchasing code writes the Finance & Sales ledgers (no
#    exception since S2).
# 2. The migrated files name nothing from Finance & Sales; they call each contract
#    with exactly the classified operations, and nothing else in Inventory &
#    Purchasing calls it.
# 3. Every other Finance & Sales reference in Inventory & Purchasing code is a
#    classified read, frozen per file (a new one fails until classified).
# 4. Each contract names nothing from Finance & Sales; each implementation never
#    drives the Inventory lifecycle; only its composition root names it, and it is
#    the registered handler.
module ArchitectureSpecs
  module InventoryFinanceGoodsReceiptPaymentBoundary
    module_function

    CONTRACT_FILE    = "app/services/inventory/goods_receipt_payment_effects.rb".freeze
    IMPLEMENTATION   = "app/services/finance/goods_receipt_payment_effects.rb".freeze
    COMPOSITION_ROOT = "config/initializers/goods_receipt_payment_effects.rb".freeze

    # Each contract → its implementation and composition root.
    CONTRACTS = {
      "Inventory::GoodsReceiptPaymentEffects" => {
        contract: CONTRACT_FILE, implementation: IMPLEMENTATION, root: COMPOSITION_ROOT,
        handler: "Finance::GoodsReceiptPaymentEffects"
      },
      "Inventory::PurchaseRequestAdvanceEffects" => {
        contract: "app/services/inventory/purchase_request_advance_effects.rb",
        implementation: "app/services/finance/purchase_request_advance_effects.rb",
        root: "config/initializers/purchase_request_advance_effects.rb",
        handler: "Finance::PurchaseRequestAdvanceEffects"
      }
    }.freeze

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

    # The services migrated in Batch S M4 → the GoodsReceiptPaymentEffects operations each calls.
    MIGRATED = {
      "app/services/inventory/goods_receipt_approval.rb"             => %w[approval_payment custody_account_active?],
      "app/services/inventory/purchase_request_advance_allocator.rb" => %w[advance_applied],
      "app/services/inventory/goods_receipt_settlement_recorder.rb"  => %w[payer_custody_account_id payment_source_kind? record_settlement],
      "app/services/inventory/goods_receipt_settlement_reverser.rb"  => %w[reverse_settlement],
      "app/services/inventory/goods_receipt_voider.rb"               => %w[reverse_all]
    }.freeze

    # The files migrated in S2 → the PurchaseRequestAdvanceEffects operations each calls.
    S2_MIGRATED = {
      "app/controllers/inventory/purchase_request_advances_controller.rb" => %w[custody_account_options],
      "app/services/inventory/purchase_request_advance_recorder.rb"       => %w[selectable_custody_account_id],
      "app/services/inventory/purchase_request_advance_workflow.rb"       => %w[advance_confirmed advance_reversed]
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
    # funding default) — file → reference lines. Since S2 the advance form, recorder
    # and workflow hold none (their custody choice and balances come from the contract).
    CLASSIFIED_REFS = {
      "app/controllers/inventory/goods_receipt_settlements_controller.rb" => 2, # own custody account + balance preview
      "app/controllers/inventory/goods_receipts_controller.rb"            => 2, # settlement list preload, own-account default
      "app/controllers/inventory/purchase_requests_controller.rb"         => 1, # advance applications on the request page
      "app/models/goods_receipt.rb"                                       => 2, # FUNDING_SOURCE_TYPES, ACCOUNTLESS kinds
      "app/models/purchase_request.rb"                                    => 4, # advance / payment totals (Settleable reads)
      "app/models/purchase_request_advance.rb"                            => 1, # SOURCE_KINDS
      "app/services/inventory/custody_payment_preview.rb"                 => 1, # receiving-screen preview
      "app/services/inventory/goods_receipt_draft_service.rb"             => 1, # the draft's own-custody funding default
      "app/views/inventory/goods_receipt_settlements/new.html.erb"        => 1, # payment source options
      "app/views/inventory/goods_receipts/show.html.erb"                  => 2  # custody payment display
    }.freeze

    CONTRACT_CALL    = /Inventory::GoodsReceiptPaymentEffects\.(\w+[?!]?)/
    S2_CONTRACT_CALL = /Inventory::PurchaseRequestAdvanceEffects\.(\w+[?!]?)/

    # Driving the Inventory lifecycle from the implementation.
    INVENTORY_LIFECYCLE = /
      \bInventory::(?!(?:GoodsReceiptPaymentEffects|PurchaseRequestAdvanceEffects)\b)\w+ | \bapproval_status\s*=(?!=)
      | \.update!?\(\s*(?:approval_status|status):
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

    def operations_called_in(path, call = CONTRACT_CALL)
      code_lines(path).flat_map { |line, _| line.scan(call).flatten }.uniq.sort
    end
  end
end

RSpec.describe "Architecture: Inventory & Purchasing reaches the payment ledgers only through its Finance & Sales contracts (Batch S, S2)" do
  boundary = ArchitectureSpecs::InventoryFinanceGoodsReceiptPaymentBoundary

  it "covers every Inventory & Purchasing glob (no stale glob or file)" do
    empty = boundary::IP_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
    expect(boundary::MIGRATED.keys + boundary::S2_MIGRATED.keys + boundary::CLASSIFIED_REFS.keys - boundary.ip_files)
      .to be_empty
  end

  it "no Inventory & Purchasing code writes the Finance & Sales ledgers (rule 1, no exception since S2)" do
    writes = boundary.ip_files.flat_map { |path| boundary.matches_in(path, boundary::FS_WRITE) }
    expect(writes).to be_empty, <<~MSG
      Write the settlement / custody ledgers through Inventory::GoodsReceiptPaymentEffects or
      Inventory::PurchaseRequestAdvanceEffects:
      #{writes.join("\n")}
    MSG
  end

  it "the migrated files name nothing from Finance & Sales (rule 2)" do
    named = (boundary::MIGRATED.keys + boundary::S2_MIGRATED.keys).flat_map { |path| boundary.matches_in(path, boundary::FS_REF) }
    expect(named).to be_empty, "Use the contract:\n#{named.join("\n")}"
  end

  it "the migrated services call exactly their classified operations, and nothing else in Inventory calls the contract (rule 2)" do
    callers = boundary.ip_files.to_h { |path| [ path, boundary.operations_called_in(path) ] }.reject { _2.empty? }
    callers.delete(boundary::CONTRACT_FILE)
    expect(callers).to eq(boundary::MIGRATED)
  end

  it "the S2 files call exactly their PurchaseRequestAdvanceEffects operations, and nothing else in Inventory does (rule 2)" do
    callers = boundary.ip_files.to_h { |path| [ path, boundary.operations_called_in(path, boundary::S2_CONTRACT_CALL) ] }
                      .reject { _2.empty? }
    callers.delete(boundary::CONTRACTS["Inventory::PurchaseRequestAdvanceEffects"][:contract])
    expect(callers).to eq(boundary::S2_MIGRATED)
  end

  it "every other Finance & Sales reference in Inventory & Purchasing is a classified read, frozen per file (rule 3)" do
    refs = boundary.ip_files.to_h { |path| [ path, boundary.matches_in(path, boundary::FS_REF).size ] }.reject { _2.zero? }
    expect(refs).to eq(boundary::CLASSIFIED_REFS)
  end

  boundary::CONTRACTS.each do |contract, files|
    describe contract do
      it "names nothing from Finance & Sales (rule 4)" do
        expect(boundary.matches_in(files[:contract], boundary::FS_REF)).to be_empty
        expect(boundary.matches_in(files[:contract], /\bFinance\b/)).to be_empty
      end

      it "has an implementation that never drives the Inventory lifecycle (rule 4)" do
        expect(boundary.matches_in(files[:implementation], boundary::INVENTORY_LIFECYCLE)).to be_empty
      end

      it "has an implementation named only by its composition root, and it is the registered handler (rule 4)" do
        name    = files[:handler]
        outside = (boundary.source_files + boundary.source_files("config"))
                  .reject { |file| [ files[:implementation], files[:root] ].include?(file) }
                  .flat_map { |file| boundary.matches_in(file, /\b#{Regexp.escape(name)}\b/) }
        expect(outside).to be_empty, "Unexpected reference to the implementation:\n#{outside.join("\n")}"
        expect(boundary.matches_in(files[:root], /#{Regexp.escape(contract)}\.register\(#{Regexp.escape(name)}\)/))
          .to be_present
        expect(contract.constantize.handler).to equal(name.constantize)
      end
    end
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

    it "catches a direct ledger write or custody read planted back into an S2 file" do
      path = "app/services/inventory/purchase_request_advance_workflow.rb"
      plant(path, "FinancialSettlementService.reverse(settlement: s, actor: u)\nCustodyAccountPolicy::Scope.new(u, CustodyAccount)\n")
      expect(boundary.matches_in(path, boundary::FS_WRITE).size).to eq(1)
      expect(boundary.matches_in(path, boundary::FS_REF).size).to eq(2)
      expect(boundary.operations_called_in(path, boundary::S2_CONTRACT_CALL)).not_to eq(boundary::S2_MIGRATED[path])
    end

    it "catches the implementation driving the Inventory lifecycle" do
      plant(boundary::IMPLEMENTATION, "receipt.update!(approval_status: \"cancelled\")\nInventory::GoodsReceiptVoider.new(x).call\n")
      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::INVENTORY_LIFECYCLE).size).to eq(2)

      s2 = boundary::CONTRACTS["Inventory::PurchaseRequestAdvanceEffects"][:implementation]
      plant(s2, "advance.update!(status: \"reversed\")\nInventory::PurchaseRequestAdvanceWorkflow.new(x).reverse!\n")
      expect(boundary.matches_in(s2, boundary::INVENTORY_LIFECYCLE).size).to eq(2)
    end
  end
end
