require 'base64'

require 'gitaly'

module Gitlab
  module GitalyClient
    module MigrationStatus
      DISABLED = 1
      OPT_IN = 2
      OPT_OUT = 3
    end

    class TooManyInvocationsError < StandardError
      attr_reader :call_site, :invocation_count, :max_call_stack

      def initialize(call_site, invocation_count, max_call_stack, most_invoked_stack)
        @call_site = call_site
        @invocation_count = invocation_count
        @max_call_stack = max_call_stack
        stacks = most_invoked_stack.join('\n') if most_invoked_stack

        msg = "GitalyClient##{call_site} called #{invocation_count} times from single request. Potential n+1?"
        msg << "\nThe following call site called into Gitaly #{max_call_stack} times:\n#{stacks}\n" if stacks

        super(msg)
      end
    end

    SERVER_VERSION_FILE = 'GITALY_SERVER_VERSION'.freeze
    MAXIMUM_GITALY_CALLS = 30

    MUTEX = Mutex.new
    private_constant :MUTEX

    def self.stub(name, storage)
      MUTEX.synchronize do
        @stubs ||= {}
        @stubs[storage] ||= {}
        @stubs[storage][name] ||= begin
          klass = Gitaly.const_get(name.to_s.camelcase.to_sym).const_get(:Stub)
          addr = address(storage)
          addr = addr.sub(%r{^tcp://}, '') if URI(addr).scheme == 'tcp'
          klass.new(addr, :this_channel_is_insecure)
        end
      end
    end

    def self.clear_stubs!
      MUTEX.synchronize do
        @stubs = nil
      end
    end

    def self.address(storage)
      params = Gitlab.config.repositories.storages[storage]
      raise "storage not found: #{storage.inspect}" if params.nil?

      address = params['gitaly_address']
      unless address.present?
        raise "storage #{storage.inspect} is missing a gitaly_address"
      end

      unless URI(address).scheme.in?(%w(tcp unix))
        raise "Unsupported Gitaly address: #{address.inspect} does not use URL scheme 'tcp' or 'unix'"
      end

      address
    end

    # All Gitaly RPC call sites should use GitalyClient.call. This method
    # makes sure that per-request authentication headers are set.
    def self.call(storage, service, rpc, request)
      enforce_gitaly_request_limits(:call)

      metadata = request_metadata(storage)
      metadata = yield(metadata) if block_given?
      stub(service, storage).__send__(rpc, request, metadata) # rubocop:disable GitlabSecurity/PublicSend
    end

    def self.request_metadata(storage)
      encoded_token = Base64.strict_encode64(token(storage).to_s)
      { metadata: { 'authorization' => "Bearer #{encoded_token}" } }
    end

    def self.token(storage)
      params = Gitlab.config.repositories.storages[storage]
      raise "storage not found: #{storage.inspect}" if params.nil?

      params['gitaly_token'].presence || Gitlab.config.gitaly['token']
    end

    # Evaluates whether a feature toggle is on or off
    def self.feature_enabled?(feature_name, status: MigrationStatus::OPT_IN)
      # Disabled features are always off!
      return false if status == MigrationStatus::DISABLED

      feature = Feature.get("gitaly_#{feature_name}")

      # If the feature has been set, always evaluate
      if Feature.persisted?(feature)
        if feature.percentage_of_time_value > 0
          # Probabilistically enable this feature
          return Random.rand() * 100 < feature.percentage_of_time_value
        end

        return feature.enabled?
      end

      # If the feature has not been set, the default depends
      # on it's status
      case status
      when MigrationStatus::OPT_OUT
        true
      when MigrationStatus::OPT_IN
        opt_into_all_features?
      else
        false
      end
    end

    # opt_into_all_features? returns true when the current environment
    # is one in which we opt into features automatically
    def self.opt_into_all_features?
      Rails.env.development? || ENV["GITALY_FEATURE_DEFAULT_ON"] == "1"
    end
    private_class_method :opt_into_all_features?

    def self.migrate(feature, status: MigrationStatus::OPT_IN)
      # Enforce limits at both the `migrate` and `call` sites to ensure that
      # problems are not hidden by a feature being disabled
      enforce_gitaly_request_limits(:migrate)

      is_enabled  = feature_enabled?(feature, status: status)
      metric_name = feature.to_s
      metric_name += "_gitaly" if is_enabled

      Gitlab::Metrics.measure(metric_name) do
        # Some migrate calls wrap other migrate calls
        allow_n_plus_1_calls do
          yield is_enabled
        end
      end
    end

    # Ensures that Gitaly is not being abuse through n+1 misuse etc
    def self.enforce_gitaly_request_limits(call_site)
      # Only count limits in request-response environments (not sidekiq for example)
      return unless RequestStore.active?

      # This is this actual number of times this call was made. Used for information purposes only
      actual_call_count = increment_call_count("gitaly_#{call_site}_actual")

      # Do no enforce limits in production
      return if Rails.env.production?

      # Check if this call is nested within a allow_n_plus_1_calls
      # block and skip check if it is
      return if get_call_count(:gitaly_call_count_exception_block_depth) > 0

      # This is the count of calls outside of a `allow_n_plus_1_calls` block
      # It is used for enforcement but not statistics
      permitted_call_count = increment_call_count("gitaly_#{call_site}_permitted")

      count_stack

      return if permitted_call_count <= MAXIMUM_GITALY_CALLS

      raise TooManyInvocationsError.new(call_site, actual_call_count, max_call_count, max_stacks)
    end

    def self.allow_n_plus_1_calls
      return yield unless RequestStore.active?

      begin
        increment_call_count(:gitaly_call_count_exception_block_depth)
        yield
      ensure
        decrement_call_count(:gitaly_call_count_exception_block_depth)
      end
    end

    def self.get_call_count(key)
      RequestStore.store[key] || 0
    end
    private_class_method :get_call_count

    def self.increment_call_count(key)
      RequestStore.store[key] ||= 0
      RequestStore.store[key] += 1
    end
    private_class_method :increment_call_count

    def self.decrement_call_count(key)
      RequestStore.store[key] -= 1
    end
    private_class_method :decrement_call_count

    # Returns an estimate of the number of Gitaly calls made for this
    # request
    def self.get_request_count
      return 0 unless RequestStore.active?

      gitaly_migrate_count = get_call_count("gitaly_migrate_actual")
      gitaly_call_count = get_call_count("gitaly_call_actual")

      # Using the maximum of migrate and call_count will provide an
      # indicator of how many Gitaly calls will be made, even
      # before a feature is enabled. This provides us with a single
      # metric, but not an exact number, but this tradeoff is acceptable
      if gitaly_migrate_count > gitaly_call_count
        gitaly_migrate_count
      else
        gitaly_call_count
      end
    end

    def self.reset_counts
      return unless RequestStore.active?

      %w[migrate call].each do |call_site|
        RequestStore.store["gitaly_#{call_site}_actual"] = 0
        RequestStore.store["gitaly_#{call_site}_permitted"] = 0
      end
    end

    def self.expected_server_version
      path = Rails.root.join(SERVER_VERSION_FILE)
      path.read.chomp
    end

    def self.timestamp(t)
      Google::Protobuf::Timestamp.new(seconds: t.to_i)
    end

    def self.encode(s)
      s.dup.force_encoding(Encoding::ASCII_8BIT)
    end

    def self.encode_repeated(a)
      Google::Protobuf::RepeatedField.new(:bytes, a.map { |s| self.encode(s) } )
    end

    # Count a stack. Used for n+1 detection
    def self.count_stack
      return unless RequestStore.active?

      stack_string = caller.drop(1).join("\n")

      RequestStore.store[:stack_counter] ||= Hash.new

      count = RequestStore.store[:stack_counter][stack_string] || 0
      RequestStore.store[:stack_counter][stack_string] = count + 1
    end
    private_class_method :count_stack

    # Returns a count for the stack which called Gitaly the most times. Used for n+1 detection
    def self.max_call_count
      return 0 unless RequestStore.active?

      stack_counter = RequestStore.store[:stack_counter]
      return 0 unless stack_counter

      stack_counter.values.max
    end
    private_class_method :max_call_count

    # Returns the stacks that calls Gitaly the most times. Used for n+1 detection
    def self.max_stacks
      return nil unless RequestStore.active?

      stack_counter = RequestStore.store[:stack_counter]
      return nil unless stack_counter

      max = max_call_count
      return nil if max.zero?

      stack_counter.select { |_, v| v == max }.keys
    end
    private_class_method :max_stacks
  end
end
