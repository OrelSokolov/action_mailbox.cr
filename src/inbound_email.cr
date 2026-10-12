# InboundEmail — the action_mailbox_inbound_emails row holding the raw
# email (an Active Storage blob attachment) and the processing status.
#
# Deliberate P0 deviation (same as action_text.cr's RichText): a
# hand-rolled row class over Base.connection instead of a full AR model,
# so status helpers (#delivered?, #bounced! …) stay overridable.
# Statuses are stored as the Rails integer enum (0..4) for DB
# compatibility.

require "openssl"

module ActionMailbox
  class InboundEmail
    TABLE = "action_mailbox_inbound_emails"

    STATUSES = ["pending", "processing", "delivered", "failed", "bounced"]

    property id : Int64?
    property status : String = "pending"
    property message_id : String
    property message_checksum : String
    property? new_record = true

    @source : String?
    @mail : Mail::Message?

    def initialize(@message_id : String, @message_checksum : String,
                   @status : String = "pending")
    end

    def self.status_index(status : String) : Int32
      STATUSES.index(status) || raise(ArgumentError.new("unknown status #{status}"))
    end

    # Create from the raw RFC822 source: extract (or generate) the
    # Message-ID, upload the source as a raw_email blob, insert the row
    # and enqueue routing (mirrors create_and_extract_message_id!).
    def self.create_and_extract_message_id!(source : String) : InboundEmail
      checksum = OpenSSL::Digest::SHA1.hexdigest(source)
      message_id = extract_message_id(source) || generate_missing_message_id(checksum)

      blob = ActiveStorage::Blob.create_and_upload!(
        io: source, filename: "message.eml", content_type: "message/rfc822"
      )

      email = new(message_id, checksum)
      email.save
      ActiveStorage::Attachment.create({
        "name"        => "raw_email",
        "record_type" => "ActionMailbox::InboundEmail",
        "record_id"   => email.id.not_nil!,
        "blob_id"     => blob.id.not_nil!,
      })
      email.route_later
      email
    end

    def self.extract_message_id(source : String) : String?
      Mail::Message.from_source(source).message_id
    rescue Exception
      nil
    end

    def self.generate_missing_message_id(checksum : String) : String
      "#{checksum}@#{System.hostname}.mail"
    end

    def self.count : Int64
      value = ActiveRecord::Base.connection.scalar("SELECT COUNT(*) FROM #{TABLE}")
      value.as(Int64)
    end

    def save : Nil
      now = Time.utc
      if (existing_id = id) && !new_record?
        ActiveRecord::Base.connection.exec(
          "UPDATE #{TABLE} SET status = $1, message_id = $2, message_checksum = $3, updated_at = $4 WHERE id = $5",
          args: [InboundEmail.status_index(status), message_id, message_checksum, now, existing_id]
        )
      else
        @id = ActiveRecord::Base.connection.scalar(
          "INSERT INTO #{TABLE} (status, message_id, message_checksum, created_at, updated_at) VALUES ($1, $2, $3, $4, $5) RETURNING id",
          args: [InboundEmail.status_index(status), message_id, message_checksum, now, now]
        ).as(Int64)
        @new_record = false
      end
    end

    def reload : InboundEmail
      if existing_id = id
        ActiveRecord::Base.connection.query(
          "SELECT status, message_id, message_checksum FROM #{TABLE} WHERE id = $1",
          [existing_id]
        ) do |rs|
          rs.each do
            @status = STATUSES[rs.read(Int32)]
            @message_id = rs.read(String)
            @message_checksum = rs.read(String)
          end
        end
      end
      self
    end

    # --- raw_email attachment ---------------------------------------------

    def raw_email_blob : ActiveStorage::Blob?
      attachment = ActiveStorage::Attachment.find_by(
        name: "raw_email",
        record_type: "ActionMailbox::InboundEmail",
        record_id: id.not_nil!
      )
      attachment.try { |a| ActiveStorage::Blob.find(a.blob_id.not_nil!) }
    end

    def source : String
      @source ||= raw_email_blob.not_nil!.download
    end

    def mail : Mail::Message
      @mail ||= Mail::Message.from_source(source)
    end

    # --- statuses ----------------------------------------------------------

    {% for s in %w(pending processing delivered failed bounced) %}
      def {{s.id}}? : Bool
        status == {{s}}
      end

      def {{s.id}}! : Nil
        @status = {{s}}
        save
      end
    {% end %}

    def processed? : Bool
      delivered? || failed? || bounced?
    end

    # --- routing -------------------------------------------------------------

    # Enqueue routing (the gem uses an ActiveJob RoutingJob; P0 keeps an
    # in-memory register of enqueued jobs — see PLAN.md deviations).
    def route_later : Nil
      ActionMailbox.enqueued_jobs << "ActionMailbox::RoutingJob"
    end

    # Route using the routing rules declared on ::ApplicationMailbox
    # (the top-level constant, exactly like the gem resolves it).
    def route : Nil
      ::ApplicationMailbox.route(self)
    end
  end
end
