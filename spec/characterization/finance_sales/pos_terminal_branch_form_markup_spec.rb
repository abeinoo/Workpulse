require "rails_helper"

module PosTerminalBranchFormMarkup
  FIXTURES = Rails.root.join("spec/fixtures/files/pos_terminal_branch_form")

  SECTION_START = '<div data-controller="line-items">'.freeze
  SECTION_END   = '<div class="divider"></div>'.freeze
  ERRORS_START  = '<div class="form-error"'.freeze

  module_function

  # The raw bytes of the terminal section of the branch form: from its
  # line-items container up to the divider that follows it.
  def terminal_section(body)
    start = body.index(SECTION_START) or raise "terminal section not found"
    body[start...body.index(SECTION_END, start)]
  end

  # The raw bytes of the shared error block ("" when the page has none).
  def error_block(body)
    start = body.index(ERRORS_START) or return ""
    body[start..(body.index("</div>", start) + "</div>".length - 1)]
  end

  # Database ids are the only run-dependent bytes: each terminal's id becomes
  # a stable placeholder — only in its hidden [id] input, the one place an id is
  # rendered. A global value="<id>" replacement also rewrote the Active
  # checkbox's literal value="1" whenever a terminal's id was 1 (a fresh
  # database, e.g. CI).
  def normalize(html, terminals)
    terminals.each_with_index.reduce(html) do |out, (terminal, index)|
      out.gsub(/value="#{terminal.id}"(?= name="branch\[pos_terminals_attributes\]\[[^\]]+\]\[id\]")/,
               %(value="__TERMINAL_#{index}_ID__"))
    end
  end

  def fixture(name) = File.read(FIXTURES.join("#{name}.html"))
end

# Characterization (Pilot 12 — POS terminals write boundary, M1, gap G4) — the
# CURRENT bytes of the branch form's terminal section and error block, which
# Pilot 12 M4 must keep identical when Branch's nested attributes are replaced
# by the OrganizationAccess::BranchTerminalSettings contract
# (next-pilot-selection.md §27.6, §27.8). The fixtures in
# spec/fixtures/files/pos_terminal_branch_form/ were recorded from the
# unchanged code; never re-record them to absorb a difference.
RSpec.describe "Characterization: branch form terminal markup", type: :request do
  include PosTerminalBranchFormMarkup

  let(:business) { create(:business) }
  let(:manager)  { api_user_with(business, :manage_branches) }
  let!(:branch)  { create(:branch, business: business, name: "Main") }

  before { sign_in manager }

  def expect_markup(name, terminals = [])
    expect(normalize(terminal_section(response.body), terminals)).to eq(fixture("#{name}_section"))
    expect(normalize(error_block(response.body), terminals)).to eq(fixture("#{name}_errors"))
  end

  it "new: no rows, the empty state shown, the NEW_INDEX template" do
    get new_admin_branch_path

    expect(response).to have_http_status(:ok)
    expect_markup("new")
  end

  it "edit: persisted rows in id order, with hidden id and _destroy, active and inactive" do
    first  = create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A", label: "Front")
    second = create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-B", active: false)

    get edit_admin_branch_path(branch)

    expect(response).to have_http_status(:ok)
    expect_markup("edit", [ first, second ])
  end

  it "update 422: submitted rows re-rendered — edited, marked for destruction, new, and new invalid" do
    first  = create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-A", label: "Front")
    second = create(:pos_terminal, business: business, branch: branch, terminal_id: "TERM-B")
    other_branch = create(:branch, business: business, name: "Other")
    create(:pos_terminal, business: business, branch: other_branch, terminal_id: "TERM-DUP")

    patch admin_branch_path(branch), params: { branch: { name: "Main", pos_terminals_attributes: {
      "0" => { id: first.id, terminal_id: "TERM-A", label: "Edited", active: "0", _destroy: "0" },
      "1" => { id: second.id, terminal_id: "TERM-B", _destroy: "1" },
      "2" => { terminal_id: "TERM-NEW", label: "New", active: "1" },
      "3" => { terminal_id: "TERM-DUP", label: "Duplicate", active: "1" }
    } } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect_markup("update_422", [ first, second ])
  end

  it "create 422: an invalid branch re-renders its new terminal rows" do
    post admin_branches_path, params: { branch: { name: "", branch_type: "sales", pos_terminals_attributes: {
      "0" => { terminal_id: "TERM-N1", label: "One", active: "1" },
      "1" => { terminal_id: "", label: "Ignored", active: "1" }
    } } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect_markup("create_422")
  end
end

# The normalization itself, without a database: ids are rendered as the app
# renders them into the committed edit fixture, then normalized back. Ids 1 and 2
# are what a fresh database (CI) assigns — the global replacement used to turn
# the Active checkbox's value="1" into a placeholder too.
RSpec.describe "Characterization: branch form terminal markup — id normalization" do
  include PosTerminalBranchFormMarkup

  def rendered_edit_section(terminals)
    terminals.each_with_index.reduce(fixture("edit_section")) do |out, (terminal, index)|
      out.gsub("__TERMINAL_#{index}_ID__", terminal.id.to_s)
    end
  end

  [ [ 1, 2 ], [ 57, 58 ] ].each do |ids|
    it "restores the fixture exactly for terminal ids #{ids.inspect}, keeping the checkboxes' literal value=\"1\"" do
      terminals = ids.map { |id| Struct.new(:id).new(id) } # only #id is read
      html      = rendered_edit_section(terminals)
      expect(html.scan('type="checkbox" value="1"').size).to eq(3)

      normalized = normalize(html, terminals)

      expect(normalized).to eq(fixture("edit_section"))
      expect(normalized.scan('type="checkbox" value="1"').size).to eq(3)
    end
  end
end
