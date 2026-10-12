# Oracle cases for ActionMailbox (Iteration 5, P0 scope: InboundEmail +
# routing DSL + process + statuses; ingress/bounce_with/incinerate P1).
#
# Run against the ORIGINAL gem:
#   ruby oracle/cases.rb > oracle/expected.yml
#
# Each line: "<case_id>\t<value>" (control chars escaped). Mirrored 1:1
# in spec/oracle_spec.cr; the port must reproduce expected.yml exactly
# (captured from actionmailbox 8.1.4, SQLite in-memory, Disk service,
# ActiveJob :test adapter — routing itself is invoked explicitly).

gem "actionmailbox", "= 8.1.4"
gem "activestorage", "= 8.1.4"
gem "activerecord", "= 8.1.4"
gem "activesupport", "= 8.1.4"
gem "activejob", "= 8.1.4"
gem "sqlite3", ">= 2.1"
require "action_mailbox"
require "active_storage"
require "active_job"
require "globalid" # AR argument serialization for RoutingJob
require "socket"   # Socket.gethostname for generated Message-IDs
require "digest"
ActiveRecord::Base.include GlobalID::Identification # railtie does this
GlobalID.app = "oracle" # railtie sets this from the app name
ActionMailbox.incinerate = false # IncinerationJob is P1 in the port
require "tmpdir"

ActiveRecord::Base.include ActiveStorage::Attached::Model
require "active_storage/reflection"
ActiveRecord::Reflection.singleton_class.prepend ActiveStorage::Reflection::ReflectionExtension
ActiveRecord::Base.include ActiveStorage::Reflection::ActiveRecordExtensions

AS_GEM = Gem::Specification.find_by_name("activestorage", "= 8.1.4").gem_dir
require "#{AS_GEM}/app/models/active_storage/record.rb"
require "#{AS_GEM}/app/models/active_storage/filename.rb"
module ActiveStorage
  class Blob < ActiveStorage::Record
    self.table_name = "active_storage_blobs"
  end
end
require "#{AS_GEM}/app/models/active_storage/blob/analyzable.rb"
require "#{AS_GEM}/app/models/active_storage/blob/identifiable.rb"
require "#{AS_GEM}/app/models/active_storage/blob/representable.rb"
require "#{AS_GEM}/app/models/active_storage/blob/servable.rb"
require "#{AS_GEM}/app/models/active_storage/blob.rb"
module ActiveStorage
  class Attachment < ActiveStorage::Record
    self.table_name = "active_storage_attachments"
  end
end
require "#{AS_GEM}/app/models/active_storage/attachment.rb"

module Rails
  def self.configuration
    @configuration ||= Config.new
  end

  class Config
    def active_storage
      @active_storage ||= StorageConfig.new
    end

    class StorageConfig
      attr_accessor :service

      def initialize
        @service = :local # non-nil skips the global-service validation
      end
    end
  end
end

AM_GEM = Gem::Specification.find_by_name("actionmailbox", "= 8.1.4").gem_dir
require "#{AM_GEM}/app/models/action_mailbox/record.rb"
# Stub first: the submodule files reopen ActionMailbox::InboundEmail::*
module ActionMailbox
  class InboundEmail < Record
    self.table_name = "action_mailbox_inbound_emails"
  end
end
require "#{AM_GEM}/app/models/action_mailbox/inbound_email/incineratable.rb"
require "#{AM_GEM}/app/models/action_mailbox/inbound_email/incineratable/incineration.rb"
require "#{AM_GEM}/app/models/action_mailbox/inbound_email/message_id.rb"
require "#{AM_GEM}/app/models/action_mailbox/inbound_email/routable.rb"
require "#{AM_GEM}/app/models/action_mailbox/inbound_email.rb"

ActiveRecord::Migration.verbose = false
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define do
  create_table :action_mailbox_inbound_emails do |t|
    t.integer :status, default: 0, null: false
    t.string  :message_id, null: false
    t.string  :message_checksum, null: false
    t.timestamps
  end
  create_table :active_storage_blobs do |t|
    t.string   :key,          null: false
    t.string   :filename,     null: false
    t.string   :content_type
    t.text     :metadata
    t.string   :service_name, null: false
    t.bigint   :byte_size,    null: false
    t.string   :checksum
    t.datetime :created_at,   null: false
  end
  create_table :active_storage_attachments do |t|
    t.string   :name,         null: false
    t.string   :record_type,  null: false
    t.integer  :record_id,    null: false
    t.integer  :blob_id,      null: false
    t.datetime :created_at,   null: false
  end
end

require "active_storage/service"
require "active_storage/service/disk_service"
require "active_storage/service/registry"
require "logger"
ROOT = Dir.mktmpdir("amb_oracle")
# keep stdout clean for the id\tvalue protocol
ActiveJob::Base.logger = Logger.new(File::NULL)
ActionMailbox.logger = Logger.new(File::NULL)
ActiveRecord::Base.logger = Logger.new(File::NULL) # generate_missing_message_id warns through it
ActiveStorage::Blob.services = ActiveStorage::Service::Registry.new(
  {"Local" => {"service" => "Disk", "root" => ROOT}})
ActiveStorage::Blob.service = ActiveStorage::Blob.services.fetch("Local")
ActionMailbox.storage_service = "Local"

# Test adapter: create only enqueues the RoutingJob; routing is invoked
# explicitly so case sequencing is deterministic.
ActiveJob::Base.queue_adapter = :test
require "#{AM_GEM}/app/jobs/action_mailbox/routing_job.rb"

# --- application mailboxes ----------------------------------------------
$processed = []
$before_ran = false

class ApplicationMailbox < ActionMailbox::Base
  routing /^replies@/i     => :replies,
          "help@example.com" => :help,
          :all               => :backstop
end

class RepliesMailbox < ApplicationMailbox
  def process
    $processed << "replies:#{inbound_email.message_id}"
  end
end

class HelpMailbox < ApplicationMailbox
  before_processing :track_before

  def process
    $processed << "help"
  end

  private
    def track_before
      $before_ran = true
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
    $processed << "should-not-run"
  end
end

class FailingMailbox < ApplicationMailbox
  def process
    raise "boom"
  end
end

class BackstopMailbox < ApplicationMailbox
  def process
    $processed << "backstop"
  end
end

def render(v)
  s = v.is_a?(String) ? v : v.inspect
  # keep the id\tvalue line protocol: escape embedded control chars
  s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

def case_run(id)
  puts "#{id}\t#{render(yield)}"
rescue StandardError => e
  if ENV["AMB_DEBUG"]
    warn "#{e.class}: #{e.message}"
    warn e.backtrace.first(10).join("\n")
  end
  puts "#{id}\traise:#{e.class.name}"
end

SOURCE = <<~MAIL
  From: david@loudthinking.com
  To: replies@example.com
  Cc: team@example.com
  Subject: Hello there
  Message-ID: <test-123@example.com>

  Hi!
MAIL

EMAIL = ActionMailbox::InboundEmail.create_and_extract_message_id!(SOURCE)

# --- message id / checksum ----------------------------------------------
case_run("mid_extracted") { EMAIL.message_id }
case_run("mid_checksum")  { EMAIL.message_checksum == OpenSSL::Digest::SHA1.hexdigest(SOURCE) }
case_run("mid_generated_shape") do
  source = <<~MAIL
    From: a@b.c
    To: d@e.f
    Subject: no mid

    body
  MAIL
  mid = ActionMailbox::InboundEmail.create_and_extract_message_id!(source).message_id
  checksum = OpenSSL::Digest::SHA1.hexdigest(source)
  mid == "#{checksum}@#{Socket.gethostname}.mail"
end

# --- pending before routing ---------------------------------------------
case_run("ie_pending")    { EMAIL.reload.status.to_s }
case_run("ie_processed")  { EMAIL.processed? }
case_run("ie_enqueued")   { ActiveJob::Base.queue_adapter.enqueued_jobs.size == 1 }
case_run("ie_job_class")  { ActiveJob::Base.queue_adapter.enqueued_jobs.first[:job].name }

# --- source & mail -------------------------------------------------------
case_run("ie_source")     { EMAIL.source == SOURCE }
case_run("mail_from")     { EMAIL.mail.from }
case_run("mail_to")       { EMAIL.mail.to }
case_run("mail_cc")       { EMAIL.mail.cc }
case_run("mail_recipients") { EMAIL.mail.recipients }
case_run("mail_subject")  { EMAIL.mail.subject }
case_run("blob_filename") { EMAIL.raw_email.blob.filename.to_s }
case_run("blob_ct")       { EMAIL.raw_email.blob.content_type }
case_run("blob_service")  { EMAIL.raw_email.blob.service_name }
case_run("blob_size")     { EMAIL.raw_email.blob.byte_size == SOURCE.bytesize }

# --- routing resolution ---------------------------------------------------
case_run("route_regex")   { ApplicationMailbox.mailbox_for(EMAIL).name }
case_run("route_string") do
  ApplicationMailbox.mailbox_for(
    ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("replies@example.com", "HELP@example.com"))
  ).name
end
case_run("route_all") do
  ApplicationMailbox.mailbox_for(
    ActionMailbox::InboundEmail.create_and_extract_message_id!(
      SOURCE.sub("To: replies@example.com", "To: unknown@nowhere.io"))
  ).name
end

# --- process lifecycle -----------------------------------------------------
EMAIL.route

case_run("recv_delivered") { EMAIL.reload.status.to_s }
case_run("recv_processed") { EMAIL.reload.processed? }
case_run("recv_ran")       { $processed == ["replies:test-123@example.com"] }

BOUNCED = ActionMailbox::InboundEmail.create_and_extract_message_id!(
  SOURCE.sub("To: replies@example.com", "To: bounce@example.com"))
BounceNowMailbox.receive(BOUNCED)
case_run("recv_bounced")   { BOUNCED.reload.status.to_s }
case_run("recv_bounced_processed") { BOUNCED.reload.processed? }

BEFORE = ActionMailbox::InboundEmail.create_and_extract_message_id!(
  SOURCE.sub("To: replies@example.com", "To: before@example.com"))
BeforeBounceMailbox.receive(BEFORE)
case_run("recv_before_bounce") do
  [BEFORE.reload.status.to_s, $processed.include?("should-not-run")]
end

FAILED = ActionMailbox::InboundEmail.create_and_extract_message_id!(
  SOURCE.sub("To: replies@example.com", "To: fail@example.com"))
begin
  FailingMailbox.receive(FAILED)
rescue StandardError
end
case_run("recv_failed")   { FAILED.reload.status.to_s }

HELPED = ActionMailbox::InboundEmail.create_and_extract_message_id!(
  SOURCE.sub("To: replies@example.com", "To: help@example.com"))
HelpMailbox.receive(HELPED)
case_run("recv_before_ran") { [$before_ran, HELPED.reload.status.to_s] }

# --- unrouted: bounced + RoutingError ---------------------------------------
UNROUTED = ActionMailbox::InboundEmail.create_and_extract_message_id!(
  SOURCE.sub("To: replies@example.com", "To: stray@example.com"))
case_run("recv_unrouted") do
  router = ActionMailbox::Router.new
  router.add_route("nobody@nowhere.io", to: :replies)
  router.route(UNROUTED)
  "no-raise"
rescue StandardError => e
  [UNROUTED.reload.status.to_s, e.class.name]
end
