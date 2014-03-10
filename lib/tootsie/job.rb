module Tootsie
  class Job

    DEFAULT_MAX_RETRIES = 5

    PROGRESS_NOTIFICATION_INTERVAL = 10.seconds

    VALID_TYPES = %w(video audio image).freeze

    def initialize(attributes = {})
      attributes = attributes.symbolize_keys
      attributes.assert_valid_keys(
        :type, :retries, :notification_url, :params, :reference)
      @type = attributes[:type].to_s
      @retries_left = attributes[:retries] || DEFAULT_MAX_RETRIES
      @created_at = Time.now
      @notification_url = attributes[:notification_url]
      @params = attributes[:params]
      @logger = Application.get.logger
      @reference = attributes[:reference]
    end

    def valid?
      return @type && VALID_TYPES.include?(@type)
    end

    def execute!
      @logger.info("Begin processing job: #{attributes.inspect}")
      notify!(:event => :started)
      begin
        result = nil
        elapsed_time = Benchmark.realtime {
          next_notify = Time.now + PROGRESS_NOTIFICATION_INTERVAL
          processor = Processors.const_get("#{@type.camelcase}Processor").new(@params)
          result = processor.execute! { |progress_data|
            if Time.now >= next_notify
              notify!(progress_data.merge(:event => :progress))
              next_notify = Time.now + PROGRESS_NOTIFICATION_INTERVAL
            end
          }
        }
        result ||= {}
        notify!({
          :event => :completed,
          :time_taken => elapsed_time
        }.merge(result))
      rescue Interrupt
        @logger.error "Job interrupted"
        notify!(:event => :failed, :reason => 'Cancelled')
        raise
      rescue => exception
        Application.get.report_exception(exception, "Job failed with exception")
        if @retries_left > 0
          @retries_left -= 1
          notify!(:event => :failed_will_retry, :reason => exception.message)

          sleep(1)
          @logger.info "Retrying job"
          retry
        else
          @logger.error "No more retries for job, marking as failed"
          notify!(:event => :failed, :reason => exception.message)
        end
      else
        @logger.info "Completed job #{attributes.inspect}"
      end
    end

    # Notify the caller of this job with some message.
    def notify!(message)
      message = message.merge(reference: @reference) if @reference

      notification_url = @notification_url
      if notification_url
        message_json = message.stringify_keys.to_json

        # TODO: Retry on failure
        @logger.info { "Notifying #{notification_url} with message: #{message_json}" }
        begin
          Excon.post(notification_url,
            :body => message_json,
            :headers => {'Content-Type' => 'application/json; charset=utf-8'})
        rescue => exception
          Application.get.report_exception(exception, "Notification failed with exception")
        end
      else
        if (river = Application.get.river)
          begin
            river.publish(message)
          rescue => exception
            Application.get.report_exception(exception, "River notification failed with exception")
          end
        end
      end
    end

    def eql?(other)
      attributes == other.attributes
    end

    def ==(other)
      other.is_a?(Job) && eql?(other)
    end

    def attributes
      return {
        :type => @type,
        :notification_url => @notification_url,
        :retries => @retries_left,
        :reference => @reference,
        :params => @params
      }
    end

    def self.from_json(data)
      new(data)
    end

    def to_json
      attributes.to_json
    end

    attr_accessor :created_at
    attr_accessor :notification_url
    attr_accessor :params
    attr_accessor :type

  end
end