require "csv"
require "digest"

class Trading212Statement::Parser
  REQUIRED = [ "Action", "Time (UTC)", "ID", "Gross Total", "Currency (Gross Total)" ].freeze
  TRADE_ACTIONS = [ "Limit buy", "Market buy", "Limit sell", "Market sell", "Stop buy", "Stop sell" ].freeze
  CASH_ACTIONS = [ "Card debit", "Card credit", "Spending cashback", "Interest on cash", "Lending interest", "Deposit", "Withdrawal" ].freeze

  def initialize(content)
    @content = content
  end

  def parse
    raise ArgumentError, "CSV exceeds upload limit" if @content.bytesize > Import::MAX_CSV_SIZE
    content = @content.dup.force_encoding(Encoding::UTF_8)
    raise ArgumentError, "CSV must be valid UTF-8" unless content.valid_encoding?
    table = CSV.parse(content.delete_prefix("\uFEFF"), headers: true)
    raise ArgumentError, "CSV headers are missing or duplicated" if table.headers.uniq != table.headers || (REQUIRED - table.headers).any?
    raise ArgumentError, "CSV has too many rows" if table.size > 20_000

    table.each_with_index.map do |row, index|
      action = row["Action"].to_s.strip
      reference = row["ID"].to_s.strip
      raw_time = row["Time (UTC)"].to_s
      raise ArgumentError, "UTC timestamp must include its timezone" unless raw_time.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      timestamp = Time.iso8601(raw_time.sub(" ", "T"))
      { "reference" => reference, "action" => action, "purchase_timestamp" => timestamp.iso8601,
        "gross" => decimal(row["Gross Total"]), "net" => row["Net Total"].present? ? decimal(row["Net Total"]) : nil,
        "currency" => row["Net Total"].present? ? row["Currency (Net Total)"] : row["Currency (Gross Total)"],
        "merchant" => row["Merchant name"].presence, "provider_category" => row["Merchant category"].presence,
        "notes" => row["Notes"].presence, "row" => index + 2 }
    rescue ArgumentError => error
      raise ArgumentError, "CSV row #{index + 2}: #{error.message}"
    end
  rescue CSV::MalformedCSVError => error
    raise ArgumentError, "Invalid CSV: #{error.message}"
  end

  private

    def decimal(value)
      amount = BigDecimal(value.to_s)
      raise ArgumentError, "Non-finite amount" unless amount.finite?
      amount.to_s("F")
    end
end
