# frozen_string_literal: true

module Puma
  class Cluster < Runner
    #—————————————————————— DO NOT USE — this class is for internal use only ———

    # Decides which workers can be promoted to a mold, and when an automatic refork
    # is due. Used by `mold_worker` when `mold_worker_candidates` is set.
    #
    # Candidates are the workers with an index below +count+. A worker that replaces a
    # candidate has the same index, so it is a candidate too. When a `mold_ready?` block
    # is configured, each candidate reports the result of the block in its status, and
    # a candidate is ready to be promoted when the block last returned true.
    #
    # An automatic refork is due when a candidate has served the current threshold, or,
    # so that a candidate that receives little traffic cannot block reforks, when the
    # other workers have served on average +fallback_factor+ times the threshold.
    # Ready candidates are promoted first. When no eligible candidate is ready,
    # promotion waits up to +ready_timeout+ seconds and then goes ahead anyway.
    class MoldCandidates # :nodoc:
      attr_reader :count, :ready_timeout, :fallback_factor

      # Returns nil when +options+ does not limit which workers are candidates.
      def self.from_options(options)
        config = options[:mold_worker_candidates]
        return unless config

        new(count: config[:count],
            ready_check: !options[:mold_ready].nil?,
            ready_timeout: config[:ready_timeout],
            fallback_factor: config[:fallback_factor])
      end

      def initialize(count:, ready_check: false, ready_timeout: 300, fallback_factor: 3)
        @count = count
        @ready_check = ready_check
        @ready_timeout = ready_timeout
        @fallback_factor = fallback_factor
        @waiting_since = nil
      end

      def candidate?(worker)
        worker.index < @count
      end

      def ready?(worker)
        !@ready_check || worker.last_status[:mold_ready].to_i == 1
      end

      # Returns the worker to promote for an automatic refork at +threshold+ requests,
      # or nil when no refork is due yet.
      def due(workers, threshold, now: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        candidates = workers.select { |w| w.booted? && candidate?(w) }
        return if candidates.empty?

        reached = candidates.select { |w| requests(w) >= threshold }
        if reached.empty?
          others = workers.reject { |w| candidate?(w) }
          return if others.empty?
          # compare the average, so that the fallback does not depend on the number of workers
          return if others.sum { |w| requests(w) } < threshold * @fallback_factor * others.size
          reached = candidates
        end

        ready = reached.select { |w| ready?(w) }
        return most_requests(ready) unless ready.empty?

        @waiting_since ||= now
        return if now - @waiting_since < @ready_timeout

        most_requests(reached)
      end

      # Returns the candidate to promote when a refork is requested or a worker needs
      # replacing: a ready candidate if there is one, otherwise any booted candidate.
      def pick(workers)
        candidates = workers.select { |w| w.booted? && candidate?(w) }
        most_requests(candidates.select { |w| ready?(w) }) || most_requests(candidates)
      end

      # Call when a refork starts or the thresholds start again.
      def reset
        @waiting_since = nil
      end

      private

      def requests(worker)
        worker.last_status[:requests_count].to_i
      end

      def most_requests(workers)
        workers.max_by { |w| requests(w) }
      end
    end
  end
end
