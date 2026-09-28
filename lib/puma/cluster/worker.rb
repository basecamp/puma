# frozen_string_literal: true

require_relative 'pipe_protocols'

module Puma
  class Cluster < Puma::Runner
    #—————————————————————— DO NOT USE — this class is for internal use only ———


    # This class is instantiated by the `Puma::Cluster` and represents a single
    # worker process.
    #
    # At the core of this class is running an instance of `Puma::Server` which
    # gets created via the `start_server` method from the `Puma::Runner` class
    # that this inherits from.
    class Worker < Puma::Runner # :nodoc:
      attr_reader :index, :master

      def initialize(index:, master:, launcher:, pipes:, app: nil)
        super(launcher)

        @index = index
        @master = master
        @check_pipe = pipes[:check_pipe]
        @worker_write = pipes[:worker_write]
        @fork_pipe = pipes[:fork_pipe]
        @wakeup = pipes[:wakeup]
        @app = app
        @server = nil
        @hook_data = {}
        @mold = false
      end

      def run
        set_proc_title

        Signal.trap "SIGINT", "IGNORE"
        Signal.trap "SIGCHLD", "DEFAULT"

        Thread.new do
          Puma.set_thread_name "wrkr check"
          @check_pipe.wait_readable
          log "! Detected parent died, dying"
          exit! 1
        end

        # If we're not running under a Bundler context, then
        # report the info about the context we will be using
        if !ENV['BUNDLE_GEMFILE']
          if File.exist?("Gemfile")
            log "+ Gemfile in context: #{File.expand_path("Gemfile")}"
          elsif File.exist?("gems.rb")
            log "+ Gemfile in context: #{File.expand_path("gems.rb")}"
          end
        end

        # Invoke any worker boot hooks so they can get
        # things in shape before booting the app.
        @config.run_hooks(:before_worker_boot, index, @log_writer, @hook_data)
        @config.run_hooks(:before_mold_candidate_boot, index, @log_writer, @hook_data) if mold_candidate?

        begin
          @server = start_server
        rescue Exception => e
          log "! Unable to start worker"
          log e
          log e.backtrace.join("\n    ")
          exit 1
        end

        restart_server = Queue.new << true << false

        fork_worker = @options[:fork_worker] && index == 0

        if fork_worker
          restart_server.clear
          worker_pids = []
          Signal.trap "SIGCHLD" do
            wakeup! if worker_pids.reject! do |p|
              Process.wait(p, Process::WNOHANG) rescue true
            end
          end

          Thread.new do
            Puma.set_thread_name "wrkr fork"
            while (idx = @fork_pipe.gets)
              idx = idx.to_i
              if idx == -1 # stop server
                if restart_server.length > 0
                  restart_server.clear
                  @server.begin_restart(true)
                  @config.run_hooks(:before_refork, nil, @log_writer, @hook_data)
                end
              elsif idx == -2 # refork cycle is done
                @config.run_hooks(:after_refork, nil, @log_writer, @hook_data)
              elsif idx == 0 # restart server
                restart_server << true << false
              else # fork worker
                worker_pids << (pid = spawn_worker(idx))
                @worker_write << "#{PIPE_FORK}#{pid}:#{idx}\n" rescue nil
              end
            end
          end
        end

        if @options[:mold_worker]
          Signal.trap("SIGURG") do
            @mold = true
            restart_server.clear
            restart_server << false
            # Do not wait for the server here; the main thread is already waiting in
            # server_thread.join, and blocking inside the trap can prevent the
            # server thread from finishing.
            @server.begin_restart
          end
        end

        Signal.trap "SIGTERM" do
          @worker_write << "#{PIPE_EXTERNAL_TERM}#{Process.pid}\n" rescue nil
          restart_server.clear
          @server.stop
          restart_server << false
        end

        begin
          @worker_write << "#{PIPE_BOOT}#{Process.pid}:#{index}\n"
        rescue SystemCallError, IOError
          STDERR.puts "Master seems to have exited, exiting."
          return
        end

        while restart_server.pop
          server_thread = @server.run
          # A promotion signal that arrived before the server started had no effect
          @server.begin_restart if @mold

          if @log_writer.debug? && index == 0
            debug_loaded_extensions "Loaded Extensions - worker 0:"
          end

          make_sure_pinging(@server)

          server_thread.join
        end

        if @mold
          set_proc_title(role: "mold")

          # Closing @fork_pipe inside the trap raises in the thread reading it, so the
          # trap writes to a separate pipe that the fork loop also waits on.
          @mold_stop_read, @mold_stop_write = IO.pipe
          Signal.trap("SIGTERM") do
            @worker_write << "#{PIPE_EXTERNAL_TERM}#{Process.pid}\n" rescue nil
            @mold_stop_write.write_nonblock(".", exception: false)
          end

          worker_pids = []
          Signal.trap "SIGCHLD" do
            wakeup! if worker_pids.reject! do |p|
              Process.wait(p, Process::WNOHANG) rescue true
            end
          end

          @config.run_hooks(:on_mold_promotion, index, @log_writer, @hook_data)

          make_sure_pinging(@server)
          wakeup!

          while (idx = next_fork_request)
            worker_pids << (pid = spawn_worker(idx))
            @worker_write << "#{PIPE_FORK}#{pid}:#{idx}\n" rescue nil
            debug "Forked worker #{idx} with pid #{pid}"
          end

          @config.run_hooks(:on_mold_shutdown, index, @log_writer, @hook_data)
        end
        # Invoke any worker shutdown hooks so they can prevent the worker
        # exiting until any background operations are completed
        @config.run_hooks(:before_worker_shutdown, index, @log_writer, @hook_data) unless @mold
      ensure
        @worker_write << "#{PIPE_TERM}#{Process.pid}\n" rescue nil
        @worker_write.close
      end

      private

      # Returns the index of the next worker to fork, or nil when the mold should stop.
      def next_fork_request
        loop do
          readable, = IO.select([@fork_pipe, @mold_stop_read])
          return nil if readable.include?(@mold_stop_read)

          # Retired molds can still be reading from the same pipe, so another
          # process may have consumed the request between select and read.
          idx = PipeProtocols::Fork.read_nonblock_from(@fork_pipe)
          return idx unless idx == :wait_readable
        end
      rescue IOError
        nil
      end

      def make_sure_pinging(server)
        # if the stat thread died, join and replace it
        if @stat_thread && !@stat_thread.alive?
          @stat_thread.join rescue nil # just ignore exceptions here
          @stat_thread = nil
        end

        @stat_thread ||= Thread.new(@worker_write) do |io|
          Puma.set_thread_name "stat pld"
          base_payload = "#{PIPE_PING}#{Process.pid}"

          while true
            begin
              payload = base_payload.dup

              hsh = @server.stats
              hsh[:mold_ready] = mold_ready? ? 1 : 0 if @options[:mold_ready] && mold_candidate? && !@mold
              hsh.each do |k, v|
                payload << %Q! "#{k}":#{v || 0},!
              end
              # sub call properly adds 'closing' string
              io << payload.sub(/,\z/, " }\n")
              @server.reset_max
            rescue SystemCallError, IOError
              break
            end
            sleep @options[:worker_check_interval]
          end
        end

      end

      # True when mold_worker_candidates allows this worker to be promoted to a mold.
      def mold_candidate?
        candidates = @options[:mold_worker_candidates]
        @options[:mold_worker] && candidates && index < candidates[:count]
      end

      def mold_ready?
        @options[:mold_ready].call ? true : false
      rescue StandardError => e
        # the block runs on every status report, so only log the first error
        log "! mold_ready? raised #{e.class}: #{e.message}" unless @mold_ready_error_logged
        @mold_ready_error_logged = true
        false
      end

      def set_proc_title(role: "worker")
        title  = "puma: #{role} #{index}: #{master}"
        title += " [#{@options[:tag]}]" if @options[:tag] && !@options[:tag].empty?
        $0 = title
      end

      def spawn_worker(idx)
        @config.run_hooks(:before_worker_fork, idx, @log_writer, @hook_data)

        pipes = {
          check_pipe: @check_pipe,
          worker_write: @worker_write,
        }

        if @options[:mold_worker]
          pipes[:fork_pipe] = @fork_pipe
          pipes[:wakeup] = @wakeup
        end

        pid = fork do
          @mold_stop_read&.close
          @mold_stop_write&.close
          new_worker = Worker.new index: idx,
                                  master: master,
                                  launcher: @launcher,
                                  pipes: pipes,
                                  app: @app
          new_worker.run
        end

        if !pid
          log "! Complete inability to spawn new workers detected"
          log "! Seppuku is the only choice."
          exit! 1
        end

        @config.run_hooks(:after_worker_fork, idx, @log_writer, @hook_data)
        pid
      end
    end
  end
end
