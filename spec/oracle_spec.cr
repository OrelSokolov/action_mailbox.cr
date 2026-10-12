# Oracle spec: the Crystal port must reproduce oracle/expected.yml
# exactly (captured from actionmailbox 8.1.4 via oracle/cases.rb:
# SQLite in-memory, Disk service, ActiveJob :test adapter — routing
# invoked explicitly). Same case IDs, no edits; values use the same
# \n/\t escape protocol.

require "spec"
require "../src/action_mailbox_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

def escape(s : String) : String
  s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

TEST_URL = ENV["AMB_TEST_URL"]? ||
           "postgres://root@/crails_as_test?host=/var/run/postgresql"

ActiveRecord::Base.establish_connection(TEST_URL)

# Clean tables between runs (oracle used a fresh in-memory DB).
ActiveRecord::Base.connection.exec("DELETE FROM action_mailbox_inbound_emails")
ActiveRecord::Base.connection.exec("DELETE FROM active_storage_attachments")
ActiveRecord::Base.connection.exec("DELETE FROM active_storage_blobs")
ActionMailbox::EnqueuedJobs.reset

ROOT = File.join(Dir.tempdir, "amb_spec_#{Random::Secure.hex(8)}")
SERVICE = ActiveStorage::DiskService.new(ROOT, "Local")
ActiveStorage.service = SERVICE

# --- application mailboxes (mirror of oracle/cases.rb) ------------------
module SpecState
  class_property processed = [] of String
  class_property before_ran = false
end

class ApplicationMailbox < ActionMailbox::Base
  routing({/^replies@/i      => :replies,
           "help@example.com" => :help,
           :all               => :backstop})
end

class RepliesMailbox < ApplicationMailbox
  def process
    SpecState.processed << "replies:#{inbound_email.message_id}"
  end
end

class HelpMailbox < ApplicationMailbox
  before_processing :track_before

  def process
    SpecState.processed << "help"
  end

  private def track_before
    SpecState.before_ran = true
  end
end

class BounceNowMailbox < ApplicationMailbox
  def process
    bounced!
  end
end

class BeforeBounceMailbox < ApplicationMailbox
  before_processing { bounced! }

  def process
    SpecState.processed << "should-not-run"
  end
end

class FailingMailbox < ApplicationMailbox
  def process
    raise "boom"
  end
end

class BackstopMailbox < ApplicationMailbox
  def process
    SpecState.processed << "backstop"
  end
end

SOURCE = "From: david@loudthinking.com\nTo: replies@example.com\nCc: team@example.com\nSubject: Hello there\nMessage-ID: <test-123@example.com>\n\nHi!\n"

EMAIL = ActionMailbox::InboundEmail.create_and_extract_message_id!(SOURCE)

CASES = {
  "mid_extracted"  => -> { EMAIL.message_id },
  "mid_checksum"   => -> { (EMAIL.message_checksum == OpenSSL::Digest::SHA1.hexdigest(SOURCE)).to_s },
  "mid_generated_shape" => -> {
    source = "From: a@b.c\nTo: d@e.f\nSubject: no mid\n\nbody\n"
    mid = ActionMailbox::InboundEmail.create_and_extract_message_id!(source).message_id
    checksum = OpenSSL::Digest::SHA1.hexdigest(source)
    (mid == "#{checksum}@#{System.hostname}.mail").to_s
  },
  "ie_pending"     => -> { EMAIL.status },
  "ie_processed"   => -> { EMAIL.processed?.to_s },
  "ie_enqueued"    => -> { (ActionMailbox.enqueued_jobs.size == 1).to_s },
  "ie_job_class"   => -> { ActionMailbox.enqueued_jobs.first },
  "ie_source"      => -> { (EMAIL.source == SOURCE).to_s },
  "mail_from"      => -> { EMAIL.mail.from.inspect },
  "mail_to"        => -> { EMAIL.mail.to.inspect },
  "mail_cc"        => -> { EMAIL.mail.cc.inspect },
  "mail_recipients" => -> { EMAIL.mail.recipients.inspect },
  "mail_subject"   => -> { EMAIL.mail.subject.to_s },
  "blob_filename"  => -> { EMAIL.raw_email_blob.not_nil!.filename.to_s },
  "blob_ct"        => -> { EMAIL.raw_email_blob.not_nil!.content_type.to_s },
  "blob_service"   => -> { EMAIL.raw_email_blob.not_nil!.service_name.to_s },
  "blob_size"      => -> { (EMAIL.raw_email_blob.not_nil!.byte_size == SOURCE.bytesize).to_s },
  "route_regex"    => -> { ApplicationMailbox.mailbox_for(EMAIL).not_nil!.name.to_s },
  "route_string"   => -> {
    email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("replies@example.com", "HELP@example.com"))
    ApplicationMailbox.mailbox_for(email).not_nil!.name.to_s
  },
  "route_all"      => -> {
    email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: unknown@nowhere.io"))
    ApplicationMailbox.mailbox_for(email).not_nil!.name.to_s
  },
}

LATER_CASES = {
  "recv_delivered"         => -> {
    EMAIL.route
    EMAIL.status
  },
  "recv_processed"         => -> { EMAIL.processed?.to_s },
  "recv_ran"               => -> { (SpecState.processed == ["replies:test-123@example.com"]).to_s },
  "recv_bounced"           => -> {
    bounced = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: bounce@example.com"))
    BounceNowMailbox.receive(bounced)
    bounced.status
  },
  "recv_bounced_processed" => -> {
    bounced = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: bounce@example.com"))
    BounceNowMailbox.receive(bounced)
    bounced.processed?.to_s
  },
  "recv_before_bounce"     => -> {
    email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: before@example.com"))
    BeforeBounceMailbox.receive(email)
    [email.status, SpecState.processed.includes?("should-not-run")].inspect
  },
  "recv_failed"            => -> {
    email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: fail@example.com"))
    (FailingMailbox.receive(email) rescue nil)
    email.status
  },
  "recv_before_ran"        => -> {
    email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: help@example.com"))
    HelpMailbox.receive(email)
    [SpecState.before_ran, email.status].inspect
  },
  "recv_unrouted"          => -> {
    email = ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: stray@example.com"))
    begin
      router = ActionMailbox::Router.new
      router.add_route("nobody@nowhere.io", to: :replies)
      router.route(email)
      "no-raise"
    rescue e : Exception
      [email.status, e.class.name].inspect
    end
  },
}

describe "action_mailbox oracle" do
  CASES.each do |id, block|
    it id do
      expected = EXPECTED[id]? || fail("missing expected value for #{id}")
      escape(block.call).should eq expected
    end
  end

  LATER_CASES.each do |id, block|
    it id do
      expected = EXPECTED[id]? || fail("missing expected value for #{id}")
      escape(block.call).should eq expected
    end
  end
end
