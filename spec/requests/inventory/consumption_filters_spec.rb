require "rails_helper"

# Consumption report: period presets, auto-applying filters, URL state.
# Issues are dated so each period's total identifies exactly which ones it
# includes (quantities are powers of two).
RSpec.describe "Inventory consumption report filters", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main") }
  let!(:outlet)  { business.warehouses.create!(name: "Outlet") }
  let!(:nasr)    { business.branches.create!(name: "Nasr Branch", active: true) }
  let!(:shubra)  { business.branches.create!(name: "Shubra Branch", active: true) }
  let!(:dye)     { business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:wax)     { business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 1, average_cost_price: 1) }

  around { |ex| travel_to(Time.zone.local(2026, 5, 15, 12)) { ex.run } }

  let(:today) { BusinessDay.current(context: business) }

  def receive(product, qty, wh: main, on: Date.new(2025, 11, 1))
    r = business.goods_receipts.build(warehouse: wh, received_on: on)
    r.items.build(product: product, quantity: qty, unit_cost: 1)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def issue(qty, on:, branch: nasr, product: dye, wh: main)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
    i.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(i).tap { |res| expect(res.ok?).to be(true) }.issue
  end

  before do
    receive(dye, 500)
    receive(wax, 500)
    receive(dye, 500, wh: outlet)
    issue(1,  on: today)                     # today / 7d / month / 3m / 6m / year
    issue(2,  on: Date.new(2026, 5, 3))      # month / 3m / 6m / year
    issue(4,  on: Date.new(2026, 4, 20))     # last month / 3m / 6m / year
    issue(8,  on: Date.new(2026, 2, 20))     # 3m / 6m / year
    issue(16, on: Date.new(2026, 1, 10), branch: shubra) # 6m / year
    issue(32, on: Date.new(2025, 12, 20))    # 6m
    issue(64, on: today, branch: shubra, product: wax)
    issue(128, on: today, branch: shubra, wh: outlet)
  end

  def total_quantity
    Nokogiri::HTML(response.body).css("#report-results tfoot td")[-2]&.text.to_s.delete(",").to_i
  end

  def selected(name)
    Nokogiri::HTML(response.body).at_css("form.report-auto-filters select[name='#{name}'] option[selected]")&.[]("value")
  end

  describe "periods" do
    before { sign_in owner }

    {
      nil          => 1 + 2 + 64 + 128,                   # default: this month
      "today"      => 1 + 64 + 128,
      "7d"         => 1 + 64 + 128,
      "month"      => 1 + 2 + 64 + 128,
      "last_month" => 4,
      "3m"         => 1 + 2 + 4 + 8 + 64 + 128,
      "6m"         => 1 + 2 + 4 + 8 + 16 + 32 + 64 + 128,
      "year"       => 1 + 2 + 4 + 8 + 16 + 64 + 128
    }.each do |period, expected|
      it "#{period || 'default (this month)'} totals #{expected}" do
        get inventory_consumption_report_path, params: { period: period }.compact
        expect(response).to have_http_status(:ok)
        expect(total_quantity).to eq(expected)
        expect(selected("period")).to eq(period || "month")
      end
    end

    it "custom range applies from/to" do
      get inventory_consumption_report_path, params: { period: "custom", from: "2026-01-01", to: "2026-02-28" }
      expect(total_quantity).to eq(16 + 8)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("input[name='from']")["value"]).to eq("2026-01-01")
      expect(doc.at_css("input[name='from']")["disabled"]).to be_nil
    end

    it "custom range combined with branch and product keeps every filter in the form and URL state" do
      get inventory_consumption_report_path,
          params: { period: "custom", from: "2025-12-01", to: "2026-05-15", branch_id: shubra.id, product_id: dye.id }
      expect(total_quantity).to eq(16 + 128) # Shubra's dye issues in the range (same query as presets)
      doc = Nokogiri::HTML(response.body)
      expect(selected("period")).to eq("custom")
      expect(selected("branch_id")).to eq(shubra.id.to_s)
      expect(selected("product_id")).to eq(dye.id.to_s)
      expect([ doc.at_css("input[name='from']")["value"], doc.at_css("input[name='to']")["value"] ]).to eq(%w[2025-12-01 2026-05-15])
      expect(doc.css("[data-report-filters-target='custom']").map { |n| n.key?("hidden") }.uniq).to eq([ false ])
    end

    it "an invalid custom range shows an error and falls back to this month" do
      get inventory_consumption_report_path, params: { period: "custom", from: "2026-03-10", to: "2026-03-01" }
      expect(response.body).to include(I18n.t("inventory.reports.period.invalid_range_fallback"))
      expect(total_quantity).to eq(1 + 2 + 64 + 128)
    end

    it "old links with only from/to are treated as a custom period" do
      get inventory_consumption_report_path, params: { from: "2026-04-01", to: "2026-04-30" }
      expect(total_quantity).to eq(4)
      expect(selected("period")).to eq("custom")
    end

    it "preset periods keep the date inputs hidden and disabled (not sent in the URL)" do
      get inventory_consumption_report_path
      doc = Nokogiri::HTML(response.body)
      expect(doc.css("[data-report-filters-target='custom']").map { |n| n.key?("hidden") }.uniq).to eq([ true ])
      expect(doc.at_css("input[name='from']")["disabled"]).to eq("disabled")
    end
  end

  describe "branch and product filters" do
    before { sign_in owner }

    it "filters by branch" do
      get inventory_consumption_report_path, params: { period: "year", branch_id: shubra.id }
      expect(total_quantity).to eq(16 + 64 + 128)
      expect(selected("branch_id")).to eq(shubra.id.to_s)
    end

    it "filters by product" do
      get inventory_consumption_report_path, params: { period: "year", product_id: wax.id }
      expect(total_quantity).to eq(64)
    end

    it "combines period + branch + product" do
      get inventory_consumption_report_path, params: { period: "month", branch_id: shubra.id, product_id: dye.id }
      expect(total_quantity).to eq(128)
      get inventory_consumption_report_path, params: { period: "last_month", branch_id: shubra.id, product_id: dye.id }
      expect(response.body).to include(I18n.t("inventory.reports.empty"))
    end

    it "keeps consumption net of voided issues" do
      voided = issue(256, on: today)
      Inventory::DocumentVoider.new(voided, user: owner, reason: "mistake").call
      get inventory_consumption_report_path, params: { period: "today", branch_id: nasr.id }
      expect(total_quantity).to eq(1)
    end
  end

  describe "URL state and auto-apply markup" do
    before { sign_in owner }

    it "the form auto-applies into the results frame and advances the URL; no filter button" do
      get inventory_consumption_report_path, params: { period: "3m", branch_id: nasr.id }
      doc = Nokogiri::HTML(response.body)
      form = doc.at_css("form.report-auto-filters")
      expect(form["method"]).to eq("get")
      expect(form["data-controller"]).to eq("report-filters")
      expect(form["data-action"]).to eq("change->report-filters#changed")
      expect(form["data-turbo-frame"]).to eq("report-results")
      expect(form["data-turbo-action"]).to eq("advance")
      expect(doc.at_css("turbo-frame#report-results")).to be_present
      expect(form.css("input[type=submit]").reject { |n| n.ancestors("noscript").any? }).to be_empty
      expect(selected("period")).to eq("3m")
      expect(selected("branch_id")).to eq(nasr.id.to_s)
    end

    it "a Turbo Frame request gets the same server-filtered results" do
      get inventory_consumption_report_path, params: { period: "last_month" }, headers: { "Turbo-Frame" => "report-results" }
      expect(response).to have_http_status(:ok)
      expect(total_quantity).to eq(4)
    end
  end

  describe "permissions" do
    it "a warehouse-scoped user only gets their branches and cannot widen the scope with a crafted branch_id" do
      role = business.permission_roles.create!(name: "OutletOnly", permissions: %w[view_inventory view_inventory_reports])
      scoped = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id); u.assigned_warehouses << outlet }
      sign_in scoped

      get inventory_consumption_report_path, params: { period: "month" }
      options = Nokogiri::HTML(response.body).css("select[name='branch_id'] option").map(&:text)
      expect(options).to include("Shubra Branch")
      expect(options).not_to include("Nasr Branch")
      expect(total_quantity).to eq(128)

      get inventory_consumption_report_path, params: { period: "month", branch_id: nasr.id }
      expect(selected("branch_id")).to be_nil
      expect(total_quantity).to eq(128) # still only their warehouse
    end
  end

  it "renders RTL in Arabic with the period labels" do
    owner.update!(preferred_locale: "ar")
    sign_in owner
    get inventory_consumption_report_path
    expect(response.body).to match(/<html[^>]*dir="rtl"/)
    expect(response.body).to include("هذا الشهر", "الشهر الماضي", "آخر 3 شهور", "مدة مخصصة", "كل الفروع", "تاريخ البداية يجب ألا يكون بعد تاريخ النهاية.")
    expect(response.body).not_to include("translation missing")
  end
end
