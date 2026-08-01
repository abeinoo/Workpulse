require "zip"

# Builds a minimal, valid .xlsx file (as raw bytes) from a 2D array of rows,
# entirely in-memory — no fixture binaries to keep in sync. Uses inline
# strings so no shared-strings table is needed; numeric values are written
# as plain numbers. Good enough for exercising Finance::PosImports::ExcelReader
# and the full import pipeline in specs.
module XlsxBuilder
  module_function

  # Wrap a Time/DateTime with this to have XlsxBuilder write it as a REAL
  # Excel datetime cell (numeric serial + a style referencing the built-in
  # "m/d/yy h:mm" number format, numFmtId 22) instead of an inline string.
  # Roo classifies a numFmtId-22 cell as :datetime and returns a Ruby
  # DateTime for it — reproducing exactly what a genuine payment-provider
  # XLSX export produces for a "Paid At" column, which is the only way to
  # exercise Finance::PosImports::ExcelReader#cell_to_s's DateTime branch
  # (plain inline-string cells, everywhere else in this builder, never hit
  # that branch at all).
  ExcelDateTime = Struct.new(:time)

  # Same idea as ExcelDateTime, but styled with a date-ONLY built-in number
  # format (numFmtId 14, "mm-dd-yy") so Roo classifies the cell as :date and
  # returns a Ruby Date rather than a DateTime.
  ExcelDate = Struct.new(:date)

  EXCEL_EPOCH = Date.new(1899, 12, 30)

  def build(rows)
    Zip::OutputStream.write_buffer do |zos|
      zos.put_next_entry("[Content_Types].xml")
      zos.write(content_types_xml)

      zos.put_next_entry("_rels/.rels")
      zos.write(rels_xml)

      zos.put_next_entry("xl/workbook.xml")
      zos.write(workbook_xml)

      zos.put_next_entry("xl/_rels/workbook.xml.rels")
      zos.write(workbook_rels_xml)

      zos.put_next_entry("xl/styles.xml")
      zos.write(styles_xml)

      zos.put_next_entry("xl/worksheets/sheet1.xml")
      zos.write(sheet_xml(rows))
    end.string
  end

  def content_types_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      </Types>
    XML
  end

  def rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
    XML
  end

  def workbook_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
          <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
        </sheets>
      </workbook>
    XML
  end

  def workbook_rels_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      </Relationships>
    XML
  end

  def styles_xml
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>
        <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="3">
          <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
          <xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
          <xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        </cellXfs>
      </styleSheet>
    XML
  end

  def sheet_xml(rows)
    body = rows.each_with_index.map { |row, r| row_xml(row, r + 1) }.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>#{body}</sheetData>
      </worksheet>
    XML
  end

  def row_xml(row, row_number)
    cells = row.each_with_index.map { |value, c| cell_xml(value, c, row_number) }.join
    "<row r=\"#{row_number}\">#{cells}</row>"
  end

  def cell_xml(value, col_index, row_number)
    ref = "#{column_letter(col_index)}#{row_number}"
    if value.is_a?(ExcelDateTime)
      "<c r=\"#{ref}\" s=\"1\"><v>#{excel_serial(value.time)}</v></c>"
    elsif value.is_a?(ExcelDate)
      "<c r=\"#{ref}\" s=\"2\"><v>#{excel_serial(value.date.to_time)}</v></c>"
    elsif value.is_a?(Numeric)
      "<c r=\"#{ref}\"><v>#{value}</v></c>"
    else
      "<c r=\"#{ref}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">#{escape(value.to_s)}</t></is></c>"
    end
  end

  # Excel serial date: whole days since 1899-12-30, plus the time-of-day as a
  # fraction of a day — the same convention Roo decodes cells with (see
  # Roo::Excelx::Workbook#base_date/#base_timestamp).
  def excel_serial(time)
    days   = (time.to_date - EXCEL_EPOCH).to_i
    frac   = (time.hour * 3600 + time.min * 60 + time.sec) / 86_400.0
    days + frac
  end

  def escape(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end

  def column_letter(index)
    letters = ""
    n = index
    loop do
      letters = ((n % 26) + 65).chr + letters
      n = (n / 26) - 1
      break if n < 0
    end
    letters
  end
end
