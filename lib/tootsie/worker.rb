module Tootsie
  class Worker

    include PrefixedLogging

    def call(event)
      payload = event.payload.except('event')
      begin
        job = Job.new(payload)
        with_job(job) do
          handle_job(job)
        end
      rescue Job::InvalidJobError => e
        logger.error "Invalid job, ignoring: #{payload.inspect}"
      rescue Pebbles::River::ConnectionError => e
        logger.error "River error, will NACK"
        return false
      end
      nil
    end

    private

      PROGRESS_NOTIFICATION_INTERVAL = 30.seconds

      def handle_job(job)
        logger.info "Starting: type=#{job.type} params=#{job.params.inspect}"

        job.notify :started
        begin
          result, elapsed_time = execute_job(job)
        rescue Interrupt
          logger.warn "Job interrupted"
          job.notify :canceled
        rescue => exception
          if retriable?(exception)
            if job.retries_left > 0
              job.retries_left -= 1
              logger.error "Job failed with exception #{exception.class} " \
                "(#{exception.message}), rescheduling with #{job.retries_left} retries left"
              job.notify :failed_will_retry, reason: exception.message
              job.publish
            else
              logger.error "No more retries for job, marking as permanently failed"
              job.notify :failed, reason: exception.message
            end
          else
            log_permanent_failure(exception)
            job.notify :failed, reason: exception.message
          end
        else
          logger.info "Completed in #{elapsed_time.round(3)} secs"
          job.notify :completed, {time_taken: elapsed_time}.merge(result)
        end
      end

      def execute_job(job)
        result = nil

        processor = Processors.const_get("#{job.type.camelcase}Processor").new(job.params)

        elapsed_time = Benchmark.realtime {
          next_notify = Time.now + PROGRESS_NOTIFICATION_INTERVAL

          result = processor.execute! { |progress_data|
            if Time.now >= next_notify
              job.notify :progress, progress_data
              next_notify = Time.now + PROGRESS_NOTIFICATION_INTERVAL
            end
          }
        }

        result ||= {}
        return result, elapsed_time
      end

      def with_job(job, &block)
        @job = job
        begin
          return yield
        ensure
          @job = nil
        end
      end

      def logger_prefix
        if @job
          "#{super}/job #{@job.uid}"
        else
          super
        end
      end

      PERMANENT_EXCEPTIONS = [
        Resources::PermanentError
      ].freeze

      def retriable?(exception)
        exception.is_a?(StandardError) &&
          !PERMANENT_EXCEPTIONS.any? { |e| exception.is_a?(e) }
      end

      def log_permanent_failure(exception)
        case exception
          when Timeout::Error, Excon::Errors::Timeout
            logger.error("The job failed due to timeout")
          when Resources::ResourceError
            logger.error("The job failed due to resource: #{exception}")
          when InputError
            logger.error("The job failed due to malformed input: #{exception}")
          else
            Configuration.instance.report_exception(exception,
              "Job permanently failed with unexpected error")
          end
      end

  end
end
