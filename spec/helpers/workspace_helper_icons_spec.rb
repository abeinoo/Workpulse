require "rails_helper"

# Every workspace navigation entry renders its section's icon by key
# (workspace_icon(section.key) — WORKSPACE_ICONS.fetch, deliberately without a
# fallback). A section added without its icon raises KeyError on every page of
# the workspace (a removed Quick Issue section once did) — this pins the registry.
RSpec.describe WorkspaceHelper, type: :helper do
  let(:source) { File.read(Rails.root.join("app/helpers/workspace_helper.rb")) }

  # The section keys of every *_workspace_config (rows "[ :key, label, path, …]").
  let(:section_keys) { source.scan(/^\s+\[ :([a-z_]+),\s/).flatten.uniq.map(&:to_sym) }

  it "finds the navigation sections it checks (Quick Issue is no longer one)" do
    expect(section_keys).to include(:overview, :issues, :settings)
    expect(section_keys).not_to include(:quick_issue)
  end

  it "has an icon for every navigation section key" do
    expect(section_keys - WorkspaceHelper::WORKSPACE_ICONS.keys).to be_empty
  end

  it "has an icon for every workspace" do
    expect(WorkspaceHelper::WORKSPACE_KEYS - WorkspaceHelper::WORKSPACE_ICONS.keys).to be_empty
  end

  it "renders each registered icon as an inline SVG" do
    WorkspaceHelper::WORKSPACE_ICONS.each_key do |key|
      expect(helper.workspace_icon(key)).to start_with("<svg").and(include("viewBox=\"0 0 24 24\"")), key.to_s
    end
  end

  it "still refuses an unknown key instead of hiding it" do
    expect { helper.workspace_icon(:no_such_icon) }.to raise_error(KeyError)
  end
end
