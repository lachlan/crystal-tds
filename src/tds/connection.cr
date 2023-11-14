require "./pre_login_request"
require "./rpc_request"
require "./prepared_statement"
require "./unprepared_statement"
require "socket"
require "http"

class TDS::Connection < DB::Connection
  @version = Version::V7_1
  @socket : TCPSocket
  @packet_size = PacketIO::MIN_SIZE

  record Options, host : String, port : Int32, user : String, password : String, database_name : String, connect_timeout : Time::Span?, read_timeout : Time::Span, isolation_level : String? do
    def self.from_uri(uri : URI) : Options
      params = HTTP::Params.parse(uri.query || "")

      host = uri.host || "localhost"
      port = uri.port || 1433
      user = uri.user || ""
      password = uri.password || ""
      database_name = File.basename(uri.path || "/")
      connect_timeout = params.has_key?("connect_timeout") ? Time::Span.new(seconds: params["connect_timeout"].to_i) : nil
      read_timeout = Time::Span.new(seconds: params.fetch("read_timeout", "30").to_i)
      isolation_level = params["isolation_level"]?

      Options.new(host: host, port: port, user: user, password: password, database_name: database_name, connect_timeout: connect_timeout, read_timeout: read_timeout, isolation_level: isolation_level)
    end
  end

  def initialize(options : DB::Connection::Options, tds_options : TDS::Connection::Options)
    super(options)

    begin
      socket = TCPSocket.new(tds_options.host, tds_options.port, connect_timeout: tds_options.connect_timeout)
    rescue exc : Socket::ConnectError
      raise DB::ConnectionRefused.new
    end
    @socket = socket
    @socket.read_timeout = tds_options.read_timeout
    case @version
    when Version::V9_0
      PacketIO.send(@socket, PacketIO::Type::PRE_LOGIN) do |io|
        PreLoginRequest.new.write(io)
      end
    when Version::V7_1
      PacketIO.send(@socket, PacketIO::Type::MSLOGIN) do |io|
        LoginRequest.new(tds_options.user, tds_options.password, appname: "crystal-tds", database_name: tds_options.database_name).write(io, @version)
      end
      PacketIO.recv(@socket, PacketIO::Type::REPLY) do |io|
        Token.each(io) do |token|
          case token
          when Token::EnvChange
            if token.type == 4_u8
              @packet_size = token.new_value.to_i
            end
          end
        end
      end
    else
      raise ::Exception.new("Unsupported version #{@version}")
    end
    self.perform_exec "SET TRANSACTION ISOLATION LEVEL #{tds_options.isolation_level}" if tds_options.isolation_level
  end

  def send(type : PacketIO::Type, &block : IO ->)
    PacketIO.send(@socket, type, @packet_size) do |io|
      block.call(io)
    end
  end

  def recv(type : PacketIO::Type, &block : IO ->)
    PacketIO.recv(@socket, type, @packet_size) do |io|
      block.call(io)
    end
  end

  def sp_prepare(params : String, statement : String, options = 0x0001_i32) : Int32
    send(PacketIO::Type::RPC) do |io|
      RpcRequest.new(id: RpcRequest::Type::PREPARE, parameters: [
        Parameter.new(nil, type_info: Int_n.new(4), status: Parameter::Status::BY_REFERENCE),
        Parameter.new(params),
        Parameter.new(statement),
        Parameter.new(options),
      ]).write(io)
    end
    result : Int32? = nil
    begin
      recv(PacketIO::Type::REPLY) do |io|
        Token.each(io) do |token|
          case token
          when Token::MetaData
          when Token::Order
          when Token::ReturnStatus
          when Token::DoneInProc
          when Token::Param
            result = token.value.as(Int32)
          else
            raise ProtocolError.new("Unexpected token #{token.inspect}")
          end
        end
      end
    rescue exc : ::Exception
      raise DB::Error.new("#{exc.to_s} while preparing \"#{statement}\"")
    end
    result.not_nil!
  end

  protected def perform_exec(statement)
    send(PacketIO::Type::QUERY) do |io|
      UTF16_IO.write(io, statement, ENCODING)
    end
    recv(PacketIO::Type::REPLY) do |io|
      begin
        Token.each(io) { |t| }
      rescue exc : ::Exception
        raise DB::Error.new("#{exc.to_s} in \"#{statement}\"")
      end
    end
  end

  def build_prepared_statement(query) : DB::Statement
    if query.includes?('?')
      PreparedStatement.new(self, query)
    else
      UnpreparedStatement.new(self, query)
    end
  end

  def build_unprepared_statement(query) : DB::Statement
    UnpreparedStatement.new(self, query)
  end

  def do_close
    @socket.close
    super
  end

  # :nodoc:
  def perform_begin_transaction
    self.perform_exec "BEGIN TRANSACTION"
  end

  # :nodoc:
  def perform_commit_transaction
    self.perform_exec "COMMIT TRANSACTION"
  end

  # :nodoc:
  def perform_rollback_transaction
    self.perform_exec "ROLLBACK TRANSACTION "
  end

  # :nodoc:
  def perform_create_savepoint(name)
    self.perform_exec "SAVE TRANSACTION #{name}"
  end

  # :nodoc:
  def perform_release_savepoint(name)
  end

  # :nodoc:
  def perform_rollback_savepoint(name)
    self.perform_exec "ROLLBACK TRANSACTION #{name}"
  end
end
