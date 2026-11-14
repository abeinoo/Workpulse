require "rails_helper"

RSpec.describe PurchaseRequest, type: :model do
  let(:business)  { create(:business) }
  let(:acme)      { business.suppliers.create!(name: "Acme") }
  let(:beta)      { business.suppliers.create!(name: "Beta") }
  let(:main_wh)   { business.warehouses.create!(name: "Main") }
  let(:annex)     { business.warehouses.create!(name: "Annex") }
  let(:product_a) { business.products.create!(name: "A", sku: "A-1", average_cost_price: 1) }
  let(:product_b) { business.products.create!(name: "B", sku: "B-1", average_cost_price: 1) }

  def request_with(warehouse: main_wh, supplier: nil, lines: [ [ product_a, nil, nil ] ])
    business.purchase_requests.build(warehouse: warehouse, supplier: supplier).tap do |pr|
      lines.each do |product, line_supplier, line_warehouse|
        pr.items.build(product: product, quantity: 1, unit_price: 1, supplier: line_supplier, source_warehouse: line_warehouse)
      end
    end
  end

  describe "warehouse" do
    it "must belong to the request's business, and must exist" do
      foreign = request_with(warehouse: create(:business).warehouses.create!(name: "Foreign"))
      expect(foreign).not_to be_valid
      expect(foreign.errors.details[:warehouse]).to include(error: :invalid)

      dangling = request_with(warehouse: nil).tap { |pr| pr.warehouse_id = Warehouse.maximum(:id).to_i + 1 }
      expect(dangling).not_to be_valid
      expect(request_with).to be_valid
    end

    it "stays optional at model level so legacy requests keep saving (services require it for new ones)" do
      expect(request_with(warehouse: nil)).to be_valid
    end
  end

  describe "#receiving_warehouse_id" do
    it "is the request's own warehouse" do
      expect(request_with(warehouse: main_wh).receiving_warehouse_id).to eq(main_wh.id)
    end

    it "falls back to the single warehouse all legacy lines named — never a guess" do
      same  = request_with(warehouse: nil, lines: [ [ product_a, nil, annex ], [ product_b, nil, annex ] ])
      mixed = request_with(warehouse: nil, lines: [ [ product_a, nil, annex ], [ product_b, nil, main_wh ] ])
      blank = request_with(warehouse: nil, lines: [ [ product_a, nil, annex ], [ product_b, nil, nil ] ])

      expect(same.receiving_warehouse_id).to eq(annex.id)
      expect(mixed.receiving_warehouse_id).to be_nil
      expect(blank.receiving_warehouse_id).to be_nil
    end
  end

  describe "#suppliers_on_items" do
    it "lists the distinct line suppliers, or the legacy request-level supplier" do
      multi = request_with(lines: [ [ product_a, acme, nil ], [ product_b, beta, nil ] ])
      expect(multi.suppliers_on_items).to contain_exactly(acme, beta)
      expect(request_with(lines: [ [ product_a, nil, nil ] ]).suppliers_on_items).to be_empty
      expect(request_with(supplier: acme).suppliers_on_items).to eq([ acme ])
    end
  end

  describe "#custody_payment_refusal (who may pay a receipt from custody)" do
    let(:rami)  { create(:user, business: business) }
    let(:other) { create(:user, business: business) }

    it "only the responsible employee; nobody while there is none" do
      pr = request_with.tap { |r| r.responsible_employee = rami }
      expect(pr.custody_payment_refusal(rami.id)).to be_nil
      expect(pr.custody_payment_refusal(other.id)).to eq(:custody_payment_responsible_only)
      expect(pr.custody_payment_refusal(nil)).to eq(:custody_payment_responsible_only)

      expect(request_with.custody_payment_refusal(rami.id)).to eq(:custody_payment_requires_responsible)
    end
  end

  describe "receiving supplier groups" do
    let(:product_c) { business.products.create!(name: "C", sku: "C-1", average_cost_price: 1) }

    it "one group per supplier with outstanding lines, the lines without a supplier last; their lines only" do
      pr = request_with(lines: [ [ product_a, nil, nil ], [ product_b, beta, nil ], [ product_c, acme, nil ] ])
      expect(pr.receiving_supplier_groups).to eq([ beta, acme, nil ])
      expect(pr.outstanding_items_for_supplier(acme.id).map(&:product)).to eq([ product_c ])
      expect(pr.outstanding_items_for_supplier(nil).map(&:product)).to eq([ product_a ])
    end

    it "a fully received line leaves its group" do
      pr = request_with(lines: [ [ product_a, acme, nil ], [ product_b, beta, nil ] ])
      done = pr.items.find { |item| item.supplier == acme }
      allow(done).to receive(:remaining_quantity).and_return(0)
      expect(pr.receiving_supplier_groups).to eq([ beta ])
      expect(pr.outstanding_items_for_supplier(acme.id)).to be_empty
    end

    it "a legacy request is one fixed group: all its outstanding lines" do
      pr = request_with(supplier: acme, lines: [ [ product_a, nil, nil ], [ product_b, nil, nil ] ])
      expect(pr.receiving_supplier_groups).to be_empty
      expect(pr.outstanding_items_for_supplier(nil).size).to eq(2)
    end
  end
end
