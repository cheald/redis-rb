# frozen_string_literal: true

require_relative "errors"
require "socket"
require "cgi"

class Redis
  class Client
    DEFAULTS = {
      url: -> { ENV["REDIS_URL"] },
      scheme: "redis",
      host: "127.0.0.1",
      port: 6379,
      path: nil,
      timeout: 5.0,
      password: nil,
      db: 0,
      driver: nil,
      id: nil,
      tcp_keepalive: 0,
      reconnect_attempts: 1,
      reconnect_delay: 0,
      reconnect_delay_max: 0.5,
      inherit_socket: false,
      sentinels: nil,
      role: nil
    }.freeze

    attr_reader :options

    def scheme
      @options[:scheme]
    end

    def host
      @options[:host]
    end

    def port
      @options[:port]
    end

    def path
      @options[:path]
    end

    def read_timeout
      @options[:read_timeout]
    end

    def connect_timeout
      @options[:connect_timeout]
    end

    def timeout
      @options[:read_timeout]
    end

    def password
      @options[:password]
    end

    def db
      @options[:db]
    end

    def db=(db)
      @options[:db] = db.to_i
    end

    def driver
      @options[:driver]
    end

    def inherit_socket?
      @options[:inherit_socket]
    end

    attr_accessor :logger
    attr_reader :connection
    attr_reader :command_map

    def initialize(options = {})
      @options = _parse_options(options)
      @reconnect = true
      @logger = @options[:logger]
      @connection = nil
      @command_map = {}

      @pending_reads = 0

      @connector =
        if !@options[:sentinels].nil?
          Connector::Sentinel.new(@options)
        elsif options.include?(:connector) && options[:connector].respond_to?(:new)
          options.delete(:connector).new(@options)
        else
          Connector.new(@options)
        end
    end

    def connect
      @pid = Process.pid

      # Don't try to reconnect when the connection is fresh
      with_reconnect(false) do
        establish_connection
        call [:auth, password] if password
        call [:select, db] if db != 0
        call [:client, :setname, @options[:id]] if @options[:id]
        @connector.check(self)
      end

      self
    end

    def id
      @options[:id] || "redis://#{location}/#{db}"
    end

    def location
      path || "#{host}:#{port}"
    end

    def call(command)
      reply = process([command]) { read }
      raise reply if reply.is_a?(CommandError)

      if block_given?
        yield reply
      else
        reply
      end
    end

    def call_loop(command, timeout = 0)
      error = nil

      result = with_socket_timeout(timeout) do
        process([command]) do
          loop do
            reply = read
            if reply.is_a?(CommandError)
              error = reply
              break
            else
              yield reply
            end
          end
        end
      end

      # Raise error when previous block broke out of the loop.
      raise error if error

      # Result is set to the value that the provided block used to break.
      result
    end

    def call_pipeline(pipeline)
      return [] if pipeline.futures.empty?

      with_reconnect pipeline.with_reconnect? do
        begin
          pipeline.finish(call_pipelined(pipeline)).tap do
            self.db = pipeline.db if pipeline.db
          end
        rescue ConnectionError => e
          return nil if pipeline.shutdown?

          # Assume the pipeline was sent in one piece, but execution of
          # SHUTDOWN caused none of the replies for commands that were executed
          # prior to it from coming back around.
          raise e
        end
      end
    end

    def call_pipelined(pipeline)
      return [] if pipeline.futures.empty?

      # The method #ensure_connected (called from #process) reconnects once on
      # I/O errors. To make an effort in making sure that commands are not
      # executed more than once, only allow reconnection before the first reply
      # has been read. When an error occurs after the first reply has been
      # read, retrying would re-execute the entire pipeline, thus re-issuing
      # already successfully executed commands. To circumvent this, don't retry
      # after the first reply has been read successfully.

      commands = pipeline.commands

      result = Array.new(commands.size)
      reconnect = @reconnect

      begin
        exception = nil

        process(commands) do
          pipeline.timeouts.each_with_index do |timeout, i|
            reply = if timeout
              with_socket_timeout(timeout) { read }
            else
              read
            end
            result[i] = reply
            @reconnect = false
            exception = reply if exception.nil? && reply.is_a?(CommandError)
          end
        end

        raise exception if exception
      ensure
        @reconnect = reconnect
      end

      result
    end

    def call_with_timeout(command, timeout, &blk)
      with_socket_timeout(timeout) do
        call(command, &blk)
      end
    rescue ConnectionError
      retry
    end

    def call_without_timeout(command, &blk)
      call_with_timeout(command, 0, &blk)
    end

    def process(commands)
      logging(commands) do
        ensure_connected do
          commands.each do |command|
            if command_map[command.first]
              command = command.dup
              command[0] = command_map[command.first]
            end

            write(command)
          end

          yield if block_given?
        end
      end
    end

    def connected?
      !!(connection && connection.connected?)
    end

    def disconnect
      connection.disconnect if connected?
    end
    alias close disconnect

    def reconnect
      disconnect
      connect
    end

    def io
      yield
    rescue TimeoutError => e1
      # Add a message to the exception without destroying the original stack
      e2 = TimeoutError.new("Connection timed out")
      e2.set_backtrace(e1.backtrace)
      raise e2
    rescue Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, Errno::EBADF, Errno::EINVAL => e
      raise ConnectionError, "Connection lost (%s)" % [e.class.name.split("::").last]
    end

    def read
      io do
        value = connection.read
        @pending_reads -= 1
        value
      end
    end

    def write(command)
      io do
        @pending_reads += 1
        connection.write(command)
      end
    end

    def with_socket_timeout(timeout)
      connect unless connected?
      original = @options[:read_timeout]

      begin
        connection.timeout = timeout
        @options[:read_timeout] = timeout # for reconnection
        yield
      ensure
        connection.timeout = self.timeout if connected?
        @options[:read_timeout] = original
      end
    end

    def without_socket_timeout(&blk)
      with_socket_timeout(0, &blk)
    end

    def with_reconnect(val = true)
      original, @reconnect = @reconnect, val
      yield
    ensure
      @reconnect = original
    end

    def without_reconnect(&blk)
      with_reconnect(false, &blk)
    end

    protected

    def logging(commands)
      return yield unless @logger&.debug?

      begin
        commands.each do |name, *args|
          logged_args = args.map do |a|
            if a.respond_to?(:inspect) then a.inspect
            elsif a.respond_to?(:to_s) then a.to_s
            else
              # handle poorly-behaved descendants of BasicObject
              klass = a.instance_exec { (class << self; self end).superclass }
              "\#<#{klass}:#{a.__id__}>"
            end
          end
          @logger.debug("[Redis] command=#{name.to_s.upcase} args=#{logged_args.join(' ')}")
        end

        t1 = Time.now
        yield
      ensure
        @logger.debug("[Redis] call_time=%0.2f ms" % ((Time.now - t1) * 1000)) if t1
      end
    end

    def establish_connection
      server = @connector.resolve.dup

      @options[:host] = server[:host]
      @options[:port] = Integer(server[:port]) if server.include?(:port)

      @connection = @options[:driver].connect(@options)
      @pending_reads = 0
    rescue TimeoutError,
           SocketError,
           Errno::EADDRNOTAVAIL,
           Errno::ECONNREFUSED,
           Errno::EHOSTDOWN,
           Errno::EHOSTUNREACH,
           Errno::ENETUNREACH,
           Errno::ENOENT,
           Errno::ETIMEDOUT,
           Errno::EINVAL => error

      raise CannotConnectError, "Error connecting to Redis on #{location} (#{error.class})"
    end

    def ensure_connected
      disconnect if @pending_reads > 0

      attempts = 0

      begin
        attempts += 1

        if connected?
          unless inherit_socket? || Process.pid == @pid
            raise InheritedError,
                  "Tried to use a connection from a child process without reconnecting. " \
                  "You need to reconnect to Redis after forking " \
                  "or set :inherit_socket to true."
          end
        else
          connect
        end

        yield
      rescue BaseConnectionError
        disconnect

        if attempts <= @options[:reconnect_attempts] && @reconnect
          sleep_t = [(@options[:reconnect_delay] * 2**(attempts - 1)),
                     @options[:reconnect_delay_max]].min

          Kernel.sleep(sleep_t)
          retry
        else
          raise
        end
      rescue Exception
        disconnect
        raise
      end
    end

    def _parse_options(options)
      return options if options[:_parsed]

      defaults = DEFAULTS.dup
      options = options.dup

      defaults.keys.each do |key|
        # Fill in defaults if needed
        defaults[key] = defaults[key].call if defaults[key].respond_to?(:call)

        # Symbolize only keys that are needed
        options[key] = options[key.to_s] if options.key?(key.to_s)
      end

      url = options[:url]
      url = defaults[:url] if url.nil?

      # Override defaults from URL if given
      if url
        require "uri"

        uri = URI(url)

        if uri.scheme == "unix"
          defaults[:path] = uri.path
        elsif uri.scheme == "redis" || uri.scheme == "rediss"
          defaults[:scheme]   = uri.scheme
          defaults[:host]     = uri.host if uri.host
          defaults[:port]     = uri.port if uri.port
          defaults[:password] = CGI.unescape(uri.password) if uri.password
          defaults[:db]       = uri.path[1..-1].to_i if uri.path
          defaults[:role] = :master
        else
          raise ArgumentError, "invalid uri scheme '#{uri.scheme}'"
        end

        defaults[:ssl] = true if uri.scheme == "rediss"
      end

      # Use default when option is not specified or nil
      defaults.keys.each do |key|
        options[key] = defaults[key] if options[key].nil?
      end

      if options[:path]
        # Unix socket
        options[:scheme] = "unix"
        options.delete(:host)
        options.delete(:port)
      else
        # TCP socket
        options[:host] = options[:host].to_s
        options[:port] = options[:port].to_i
      end

      if options.key?(:timeout)
        options[:connect_timeout] ||= options[:timeout]
        options[:read_timeout]    ||= options[:timeout]
        options[:write_timeout]   ||= options[:timeout]
      end

      options[:connect_timeout] = Float(options[:connect_timeout])
      options[:read_timeout]    = Float(options[:read_timeout])
      options[:write_timeout]   = Float(options[:write_timeout])

      options[:reconnect_attempts] = options[:reconnect_attempts].to_i
      options[:reconnect_delay] = options[:reconnect_delay].to_f
      options[:reconnect_delay_max] = options[:reconnect_delay_max].to_f

      options[:db] = options[:db].to_i
      options[:driver] = _parse_driver(options[:driver]) || Connection.drivers.last

      case options[:tcp_keepalive]
      when Hash
        %i[time intvl probes].each do |key|
          unless options[:tcp_keepalive][key].is_a?(Integer)
            raise "Expected the #{key.inspect} key in :tcp_keepalive to be an Integer"
          end
        end

      when Integer
        if options[:tcp_keepalive] >= 60
          options[:tcp_keepalive] = { time: options[:tcp_keepalive] - 20, intvl: 10, probes: 2 }

        elsif options[:tcp_keepalive] >= 30
          options[:tcp_keepalive] = { time: options[:tcp_keepalive] - 10, intvl: 5, probes: 2 }

        elsif options[:tcp_keepalive] >= 5
          options[:tcp_keepalive] = { time: options[:tcp_keepalive] - 2, intvl: 2, probes: 1 }
        end
      end

      options[:_parsed] = true

      options
    end

    def _parse_driver(driver)
      driver = driver.to_s if driver.is_a?(Symbol)

      if driver.is_a?(String)
        begin
          require_relative "connection/#{driver}"
        rescue LoadError, NameError
          begin
            require "connection/#{driver}"
          rescue LoadError, NameError => error
            raise "Cannot load driver #{driver.inspect}: #{error.message}"
          end
        end

        driver = Connection.const_get(driver.capitalize)
      end

      driver
    end

    class Connector
      def initialize(options)
        @options = options.dup
      end

      def resolve
        @options
      end

      def check(client); end

      class Sentinel < Connector
        EXPECTED_ROLES = {
          "nearest_slave" => "slave",
          "nearest" => "any"
        }.freeze

        def initialize(options)
          super(options)

          @options[:db] = DEFAULTS.fetch(:db)

          @sentinels = @options.delete(:sentinels).dup
          @role = (@options[:role] || "master").to_s
          @master = @options[:host]
        end

        def check(client)
          # Check the instance is really of the role we are looking for.
          # We can't assume the command is supported since it was introduced
          # recently and this client should work with old stuff.
          expected_role = EXPECTED_ROLES.fetch(@role, @role)
          begin
            role = client.call([:role])[0]
          rescue Redis::CommandError
            # Assume the test is passed if we can't get a reply from ROLE...
            role = expected_role
          end

          if role != expected_role && expected_role != "any"
            client.disconnect
            raise ConnectionError, "Instance role mismatch. Expected #{expected_role}, got #{role}."
          end
        end

        def resolve
          result = case @role
          when "master"
            resolve_master
          when "slave"
            resolve_slave
          when "nearest"
            resolve_nearest
          when "nearest_slave"
            resolve_nearest_slave
          else
            raise ArgumentError, "Unknown instance role #{@role}"
          end

          result || (raise ConnectionError, "Unable to fetch #{@role} via Sentinel.")
        end

        def sentinel_detect
          @sentinels.each do |sentinel|
            client = Client.new(@options.merge({
                                                 host: sentinel[:host] || sentinel["host"],
                                                 port: sentinel[:port] || sentinel["port"],
                                                 password: sentinel[:password] || sentinel["password"],
                                                 reconnect_attempts: 0
                                               }))

            begin
              if result = yield(client)
                # This sentinel responded. Make sure we ask it first next time.
                @sentinels.delete(sentinel)
                @sentinels.unshift(sentinel)

                return result
              end
            rescue BaseConnectionError
            ensure
              client.disconnect
            end
          end

          raise CannotConnectError, "No sentinels available."
        end

        def resolve_master
          sentinel_detect do |client|
            if reply = client.call(["sentinel", "get-master-addr-by-name", @master])
              { host: reply[0], port: reply[1] }
            end
          end
        end

        def resolve_slave
          sentinel_detect do |client|
            if reply = client.call(["sentinel", "slaves", @master])
              slaves = reply.map { |s| s.each_slice(2).to_h }
              slaves.each { |s| s['flags'] = s.fetch('flags').split(',') }
              slaves.reject! { |s| s.fetch('flags').include?('s_down') }

              if slaves.empty?
                raise CannotConnectError, 'No slaves available.'
              else
                slave = slaves.sample
                {
                  host: slave.fetch('ip'),
                  port: slave.fetch('port')
                }
              end
            end
          end
        end

        def resolve_nearest
          resolve_nearest_for %I(master slaves)
        end

        def resolve_nearest_slave
          resolve_nearest_for %I(slaves)
        end

        def resolve_nearest_for(types)
          sentinel_detect do |client|
            ok_nodes = []
            types.each do |type|
              reply = client.call(["sentinel", type, @master])
              next unless reply

              reply = [reply] if type == :master
              ok_nodes += reply.map { |r| Hash[*r] }.select do |r|
                case type
                when :master
                  r["role-reported"] == "master"
                when :slaves
                  r["master-link-status"] == "ok" && !r.fetch("flags", "").match(/s_down|disconnected/)
                end
              end
            end

            ok_nodes.each do |node|
              client = Client.new @options.merge(
                host: node["ip"],
                port: node["port"],
                reconnect_attempts: 0
              )
              begin
                client.call [:ping]
                start = Time.now
                client.call [:ping]
                node["response_time"] = (Time.now - start).to_f
              ensure
                client.disconnect
              end
            end

            node = ok_nodes.min_by { |n| n["response_time"] }
            { host: node.fetch("ip"), port: node.fetch("port") } if node
          end
        end
      end
    end
  end
end
