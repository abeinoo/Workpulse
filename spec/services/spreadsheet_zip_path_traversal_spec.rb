require "rails_helper"

# Regression for CVE-2026-85396 (rubyzip < 3.4.0): Zip::Entry#extract compared
# the extraction path with the destination by prefix without a trailing
# separator, so an entry named "../<dest>_backup/x" escaped into a sibling
# directory sharing the destination's prefix. Every uploaded .xlsx is unzipped
# by Roo, so both the dependency itself and the three import readers are
# checked here, each inside its own throwaway directory tree.
RSpec.describe "Spreadsheet uploads — zip path traversal" do
  around do |example|
    Dir.mktmpdir("zip_traversal") do |base|
      @base    = base
      @work    = File.join(base, "work")
      @sibling = File.join(base, "work_backup")
      FileUtils.mkdir_p([ @work, @sibling ])

      saved = ENV.to_h.slice("TMPDIR", "ROO_TMP")
      ENV["TMPDIR"] = ENV["ROO_TMP"] = @work
      begin
        example.run
      ensure
        %w[TMPDIR ROO_TMP].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
      end
    end
  end

  let(:marker) { "owned_#{SecureRandom.hex(6)}" }

  def zip_with(entries, base_bytes: nil)
    Zip::OutputStream.write_buffer(StringIO.new) do |out|
      if base_bytes
        Zip::InputStream.open(StringIO.new(base_bytes)) do |input|
          while (entry = input.get_next_entry)
            out.put_next_entry(entry.name)
            out.write(input.read)
          end
        end
      end
      entries.each do |name, data|
        out.put_next_entry(name)
        out.write(data)
      end
    end.string
  end

  def files_outside_work
    Dir.glob(File.join(@base, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .reject { |path| path.start_with?(@work + File::SEPARATOR) }
  end

  def marker_files_anywhere
    [ @base, Rails.root.to_s, Dir.pwd ].uniq.flat_map do |root|
      Dir.glob(File.join(root, "**", "#{marker}*"))
    end
  end

  it "rubyzip refuses to extract an entry into a sibling directory sharing the destination prefix" do
    bytes = zip_with({ "../work_backup/#{marker}.sh" => "echo owned" })

    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      expect { zip.entries.each { |entry| entry.extract(destination_directory: @work) } }
        .to output(/unsafe/).to_stderr
    end

    expect(Dir.children(@sibling)).to be_empty
    expect(files_outside_work).to be_empty
  end

  context "when an uploaded .xlsx carries traversal entries next to a valid workbook" do
    let(:upload) do
      zip_with(
        {
          "../work_backup/#{marker}.sh" => "echo owned",
          "../../#{marker}.txt" => "owned",
          "xl/media/image1/../../../work_backup/#{marker}.png" => "owned"
        },
        base_bytes: XlsxBuilder.build([ %w[SKU Quantity], [ "UYN1", 2 ] ])
      )
    end

    after do
      expect(Dir.children(@sibling)).to be_empty
      expect(files_outside_work).to be_empty
      expect(marker_files_anywhere).to be_empty
    end

    it "stock issue import reads the sheet without writing outside its temp directory" do
      csv = Inventory::Imports::SpreadsheetReader.to_csv(upload, filename: "stock.xlsx")
      expect(CSV.parse(csv)).to eq([ %w[SKU Quantity], %w[UYN1 2] ])
    end

    it "bank statement import reads the sheet without writing outside its temp directory" do
      table = Finance::BankStatements::FileReader::ExcelReader.new(upload, filename: "statement.xlsx").read
      expect(table.headers).to eq(%w[SKU Quantity])
    end

    it "POS import reads the sheet without writing outside its temp directory" do
      grid = Finance::PosImports::ExcelReader.call(upload, filename: "report.xlsx")
      expect(grid.rows).to eq([ %w[SKU Quantity], %w[UYN1 2] ])
    end
  end
end
