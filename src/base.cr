# Base — the mailbox base class: processing lifecycle with status
# tracking (pending → processing → delivered / bounced / failed) and the
# routing DSL. before_processing callbacks can halt the chain by
# bouncing (the gem's callback terminator: finished_processing?).

module ActionMailbox
  module EnqueuedJobs
    class_property jobs = [] of String

    def self.reset : Nil
      jobs.clear
    end
  end

  def self.enqueued_jobs : Array(String)
    EnqueuedJobs.jobs
  end

  class Base
    getter inbound_email : InboundEmail

    MAILBOXES = [] of TypeNode

    macro inherited
      {% ActionMailbox::Base::MAILBOXES << @type %}
    end

    def __run_before_processing : Nil
      nil
    end

    @@router = Router.new
    @@mailboxes = {} of String => Base.class

    def self.router : Router
      @@router
    end

    def self.register_mailbox(name : String, klass : Base.class) : Nil
      @@mailboxes[name] = klass
    end

    def self.mailbox_for_name(name : String) : Base.class
      @@mailboxes.fetch(name) do
        raise ArgumentError.new("unknown mailbox :#{name}")
      end
    end

    def self.route(inbound_email : InboundEmail) : Nil
      @@router.route(inbound_email)
    end

    def self.mailbox_for(inbound_email : InboundEmail) : Base.class | Nil
      @@router.mailbox_for(inbound_email)
    end

    def self.receive(inbound_email : InboundEmail) : Nil
      new(inbound_email).perform_processing
    end

    def initialize(@inbound_email : InboundEmail)
    end

    def mail : Mail::Message
      inbound_email.mail
    end

    # delegate :mail, :delivered!, :bounced! (the gem's Base)
    def delivered! : Nil
      inbound_email.delivered!
    end

    def bounced! : Nil
      inbound_email.bounced!
    end

    def process : Nil
      # Override in subclasses
    end

    def perform_processing : Nil
      track_status_of_inbound_email do
        __run_before_processing
        process unless finished_processing?
      end
    end

    def finished_processing? : Bool
      inbound_email.delivered? || inbound_email.bounced?
    end

    # --- before_processing DSL --------------------------------------------
    # Callback methods are prefixed amb_before__cb_ and assembled into
    # __run_before_processing by the module-level finished hook (a class
    # `macro finished` does not fire for subclasses — same reason the AR
    # port keeps a MODELS registry).

    macro before_processing(method_name = nil, &block)
      {% n = @type.methods.select { |m| m.name.stringify.starts_with?("amb_before__cb_") }.size %}
      def amb_before__cb_{{n.id}}
        {% if method_name %}{{method_name.id}}{% else %}{{block.body}}{% end %}
        nil
      end
    end

    private def track_status_of_inbound_email(&) : Nil
      inbound_email.processing!
      yield
      inbound_email.delivered! unless inbound_email.bounced?
    rescue e : Exception
      inbound_email.failed!
      raise e
    end
  end
end

# Wire the routing DSL into mailbox classes (the gem: Routing concern
# with a class-level router; the mailbox_name → class resolution is a
# compile-time constant lookup here).
class ActionMailbox::Base
  macro routing(routes)
    {% for key, value in routes %}
      {% mailbox_name = value.id.stringify %}
      {% klass = (mailbox_name.camelcase + "Mailbox").id %}
      ::ActionMailbox::Base.register_mailbox({{mailbox_name}}, {{klass}})
      router.add_route({{key}}, {{mailbox_name}})
    {% end %}
  end
end

# Assemble each mailbox subclass's before_processing callbacks (a class
# `macro finished` does not fire for subclasses, hence the registry —
# the same layout the ActiveRecord port uses for its runners).
module ActionMailbox
  macro finished
    {% for t in ActionMailbox::Base::MAILBOXES %}
      class ::{{ t.stringify.id }}
        def __run_before_processing : Nil
          {% for m in t.methods %}
            {% if m.name.stringify.starts_with?("amb_before__cb_") %}{{ m.name.id }}{% end %}
          {% end %}
          nil
        end
      end
    {% end %}
  end
end
