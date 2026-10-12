# Inbound mail parsing — the Mail::Message builder in action_mailer.cr
# assembles outgoing mail; this reopen adds the reading side the gem's
# `Mail.from_source` provides: unfolded headers, address lists
# (to/cc/bcc), subject, Message-ID and the raw body.

class Mail::Message
  property cc_addresses : Array(String) = [] of String
  property bcc_addresses : Array(String) = [] of String
  property message_id_field : String? = nil
  property raw_source : String = ""

  def self.from_source(source : String) : self
    message = Message.new
    message.raw_source = source

    header_text, _, body_text = source.partition(/\r?\n\r?\n/)
    headers = unfold_headers(header_text)

    message.from = headers["from"]?.try { |v| split_addresses(v).first? }
    message.to = headers["to"]?.try { |v| split_addresses(v).first? }
    message.cc_addresses = headers["cc"]?.try { |v| split_addresses(v) } || [] of String
    message.bcc_addresses = headers["bcc"]?.try { |v| split_addresses(v) } || [] of String
    message.subject = headers["subject"]?
    message.message_id_field = headers["message-id"]?.try(&.strip)
    message.set_single_body(body_text || "")
    message
  end

  # mail gem: recipients = to + cc + bcc (address-wrapped)
  def cc : Array(String)
    cc_addresses
  end

  def bcc : Array(String)
    bcc_addresses
  end

  def recipients : Array(String)
    to + cc_addresses + bcc_addresses
  end

  # mail gem strips the angle brackets
  def message_id : String?
    message_id_field.try(&.gsub(/^<|>$/, ""))
  end

  # --- parsing helpers --------------------------------------------------

  private def self.unfold_headers(header_text : String) : Hash(String, String)
    headers = {} of String => String
    current : String? = nil
    header_text.each_line do |line|
      if line.starts_with?(' ') || line.starts_with?('\t')
        if key = current
          headers[key] = "#{headers[key]} #{line.strip}"
        end
      elsif (idx = line.index(':'))
        key = line[0, idx].strip.downcase
        headers[key] = line[idx + 1..].strip
        current = key
      end
    end
    headers
  end

  private def self.split_addresses(value : String) : Array(String)
    value.split(',').map(&.strip).reject(&.empty?)
  end
end
