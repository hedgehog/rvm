require 'open3'

module RVM
  module Shell

    class Processes
      class <<self
        def list
          @list ||= []
        end

        def stop_processes!
          list.each do |_, process|
            process.stop
          end
        end

        def register_process(process)
          list << [process.key, process]
        end

        def get_process(key)
          found = list.find{ |id, _| id == key }
          found[-1] if found
        end

        def only_processes
          list.collect{ |_, process| process }
        end
      end

    end

    class Process
      include Shellwords

      attr_reader :key

      def initialize(cmd, exit_timeout, io_wait)
        @started = false
        @stopped = false

        @exit_timeout = exit_timeout
        @io_wait = io_wait
        @key = command_key(cmd)
        @process = ChildProcess.build(*shellwords(cmd))
        reopen_stdout
        reopen_stderr
        @process.duplex = true
        @process
      end

      def run!(&block)
        @process.start
        @started = true
        yield self if block_given?
      end

      def stdin
        wait_for_io do
          @process.io.stdin
        end
      end

      def reopen(stream)
        case stream
          when :stdout
            reopen_stdout
          when :stderr
            reopen_stderr
        end
      end

      # Ensure we can lookup a command's process from some list.
      def command_key(command)
        ::Digest::MD5.hexdigest(command)
      end

      def started?
        @started
      end

      def runable?
         stdin.closed?
      end

      def output
        stdout + stderr
      end

      def stdout
        wait_for_io do
          @out.rewind
          @out.read
        end
      end

      def stderr
        wait_for_io do
          @err.rewind
          @err.read
        end
      end

      def stop(exit_timeout = @exit_timeout)
        if @process
          stdout && stderr # flush output
          @stopped = @process.stop(exit_timeout)
          @process.exit_code
        end
      end

      def exit_code
        @process.exit_code
      end

      def exited?
        @process.exited?
      end

      def stopped?
        @stopped
      end

      def crashed?
        @process.crashed?
      end

      def reopen_stdout
        @out = Tempfile.new("rvm-out")
        @process.io.stdout = @out
#        @out.unlink if @out
        #@out = out
      end

      def reopen_stderr
        @err = Tempfile.new("rvm-err")
        @process.io.stderr = @err
#        @err.unlink if @err
        #@err = err
      end

      private


      def wait_for_io(&block)
        sleep @io_wait if @process.alive?
        yield
      end
    end

    # Implementation of the abstract wrapper class that opens a new
    # instance of bash when a command is run, only keeping it around
    # for the lifetime of the command. Possibly inefficient but for
    # the moment simplest and hence default implementation.
    class SingleShotWrapper < AbstractWrapper

      attr_accessor :process

      def initialize(cmd='bash', key='bash', &setup_block)
        @started = false
        super

        @exit_timeout = 2
        @io_wait = 2

        @process = Process.new(cmd, @exit_timeout, @io_wait)
        Processes.register_process(@process)
        @process.run!
        @started = true
        #invoke_setup!
        @setup_block = nil
        @process
      end

      def started?
        @started
      end

      # Runs a given command in the current shell.
      # Defaults the command to true if empty.
      def run_command(command)
        command = "true" if command.to_s.strip.empty?
        begin
          @last_exit_status, status, out, err = with_shell_instance(command) do |process|
            process.stdin.write(input_cmd( command )) unless process.exited? || process.crashed?
            #process.stdin.close if process.stdin && !process.stdin.closed?
            out, err = process.stdout, process.stderr
            out, status, _ = raw_stdout_to_parts(out)
            [process.exit_code, status, out, err]
          end
        rescue => e
          puts e.message
          puts e.backtrace.join('\n')
          raise
        end
        @rvm_exit_status = status['exit_status'].to_i
        @last_exit_status = @rvm_exit_status unless @process.exit_code
        if(@last_exit_status != 0)
          fail("Last exit status was #{@last_exit_status}. Output:\n TODO \#{all_output}")
        end
        if(@rvm_exit_status != 0)
          fail("RVM parsed exit status was #{@rvm_exit_status}. Output:\n TODO \#{all_output}")
        end
        return @rvm_exit_status, status, out, err
      end

      # Runs a command, ensuring no output is collected.
      def run_command_silently(command)
        with_shell_instance(command) do |process|
          process.stdin.write input_cmd(silent_command(command))
        end
      end

      def input_cmd(command)
        ensure_newline(wrapped_command(command))
      end

      private

      def wait_for_io(&block)
        sleep @io_wait if @process.alive?
        yield
      end

      def write_cmd(input)
        stdin.write(input)
      end

      def ensure_newline(str)
        str.chomp << "\n"
      end

      protected

      # yields stdio, stderr and stdin for a shell instance.
      # If there isn't a current shell instance, it will create a new one.
      # In said scenario, it will also cleanup once it is done.
      def with_shell_instance(command, &blk)
        key = command_key(command)
        @process = Processes.get_process(key) if @process.nil? || key != @process.key
        no_current = @process.nil? || @process.exited? || @process.crashed?
        if no_current
          announce_or_puts("$ cd #{Dir.pwd}") if @announce_dir
          announce_or_puts("$ #{command}") if @announce_cmd
#         @current = Open3.popen3(self.shell_executable)
          SingleShotWrapper.new(command, key)
          @process = Processes.get_process(key)
        end
        # invoke_setup! can return us here without a @process = nil I think the setup can be dropped
        # since we had to setup each command with a source load... tough to know without any specs.
        if block_given?
#          SingleShotWrapper.new(*shellwords(self.shell_executable), key) if @process.nil?
          yield(@process)
        else
          @process
        end
      ensure
        @process = nil if no_current
        @last_exit_status
      end

      def current_dir
        File.join(*dirs)
      end

      def dirs
        @dirs ||= ['tmp/aruba']
      end

    end
  end
end
