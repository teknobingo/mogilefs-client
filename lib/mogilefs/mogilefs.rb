require 'socket'
require 'timeout'

require 'mogilefs/client'
require 'mogilefs/nfsfile'
require 'mogilefs/util'

##
# Timeout error class.

class MogileFS::Timeout < Timeout::Error; end

##
# MogileFS File manipulation client.

class MogileFS::MogileFS < MogileFS::Client

  include MogileFS::Util

  ##
  # The path to the local MogileFS mount point if you are using NFS mode.

  attr_reader :root

  ##
  # The domain of keys for this MogileFS client.

  attr_reader :domain

  ##
  # The timeout for get_file_data.  Defaults to five seconds.

  attr_accessor :get_file_data_timeout

  ##
  # Creates a new MogileFS::MogileFS instance.  +args+ must include a key
  # :domain specifying the domain of this client.  A key :root will be used to
  # specify the root of the NFS file system.

  def initialize(args = {})
    @domain = args[:domain]
    @root = args[:root]

    @get_file_data_timeout = 5

    raise ArgumentError, "you must specify a domain" unless @domain

    super
  end

  ##
  # Enumerates keys starting with +key+.

  def each_key(prefix)
    after = nil

    keys, after = list_keys prefix

    until keys.nil? or keys.empty? do
      keys.each { |k| yield k }
      keys, after = list_keys prefix, after
    end

    return nil
  end

  ##
  # Retrieves the contents of +key+.

  def get_file_data(key, &block)
    paths = get_paths key

    return nil unless paths

    paths.each do |path|
      next unless path
      case path
      when /^http:\/\// then
        path = URI.parse(path)
        sock = nil
        begin
          timeout @get_file_data_timeout, MogileFS::Timeout do
            sock = TCPSocket.new(path.host, path.port)
            sock.sync = true
            sock.syswrite("GET #{path.request_uri} HTTP/1.0\r\n\r\n")
            buf = sock.recv(4096, Socket::MSG_PEEK)
            head, body = buf.split(/\r\n\r\n/, 2)
            head = sock.recv(head.size + 4)
          end

          return block_given? ? yield(sock) : sock.read
        rescue MogileFS::Timeout, Errno::ECONNREFUSED,
               EOFError, SystemCallError
          next
        end
      else
        next unless File.exist? path
        return File.read(path)
      end
    end

    return nil
  end

  ##
  # Get the paths for +key+.

  def get_paths(key, noverify = true, zone = nil)
    noverify = noverify ? 1 : 0
    res = @backend.get_paths(:domain => @domain, :key => key,
                             :noverify => noverify, :zone => zone)
    paths = (1..res['paths'].to_i).map { |i| res["path#{i}"] }
    return paths if paths.empty?
    return paths if paths.first =~ /^http:\/\//
    return paths.map { |path| File.join @root, path }
  end

  ##
  # Creates a new file +key+ in +klass+.  +bytes+ is currently unused.
  #
  # The +block+ operates like File.open.

  def new_file(key, klass, bytes = 0, &block) # :yields: file
    raise MogileFS::ReadOnlyError if readonly?

    res = @backend.create_open(:domain => @domain, :class => klass,
                               :key => key, :multi_dest => 1)

    dests = nil

    if res.include? 'dev_count' then # HACK HUH?
      dests = (1..res['dev_count'].to_i).map do |i|
        [res["devid_#{i}"], res["path_#{i}"]]
      end
    else
      # 0x0040:  d0e4 4f4b 2064 6576 6964 3d31 2666 6964  ..OK.devid=1&fid
      # 0x0050:  3d33 2670 6174 683d 6874 7470 3a2f 2f31  =3&path=http://1
      # 0x0060:  3932 2e31 3638 2e31 2e37 323a 3735 3030  92.168.1.72:7500
      # 0x0070:  2f64 6576 312f 302f 3030 302f 3030 302f  /dev1/0/000/000/
      # 0x0080:  3030 3030 3030 3030 3033 2e66 6964 0d0a  0000000003.fid..

      dests = [[res['devid'], res['path']]]
    end

    dest = dests.first
    devid, path = dest

    case path
    when nil, '' then
      raise EmptyPathError
    when /^http:\/\// then
      MogileFS::HTTPFile.open(self, res['fid'], path, devid, klass, key,
                              dests, bytes, &block)
    else
      MogileFS::NFSFile.open(self, res['fid'], path, devid, klass, key, &block)
    end
  end

  ##
  # Copies the contents of +file+ into +key+ in class +klass+.  +file+ can be
  # either a file name or an object that responds to #read.

  def store_file(key, klass, file)
    raise MogileFS::ReadOnlyError if readonly?

    new_file key, klass do |mfp|
      if file.respond_to? :sysread then
        return sysrwloop(file, mfp)
      else
	if File.size(file) > 0x10000 # Bigass file, handle differently
	  mfp.bigfile = file
	  return mfp.close
	else
          return File.open(file) { |fp| sysrwloop(fp, mfp) }
        end
      end
    end
  end

  ##
  # Stores +content+ into +key+ in class +klass+.

  def store_content(key, klass, content)
    raise MogileFS::ReadOnlyError if readonly?

    new_file key, klass do |mfp|
      mfp << content
    end

    return content.length
  end

  ##
  # Removes +key+.

  def delete(key)
    raise MogileFS::ReadOnlyError if readonly?

    @backend.delete :domain => @domain, :key => key
  end

  ##
  # Sleeps +duration+.

  def sleep(duration)
    @backend.sleep :duration => duration
  end

  ##
  # Renames a key +from+ to key +to+.

  def rename(from, to)
    raise MogileFS::ReadOnlyError if readonly?

    @backend.rename :domain => @domain, :from_key => from, :to_key => to
    nil
  end

  ##
  # Returns the size of +key+.
  def size(key)
    paths = get_paths(key) or return nil
    paths_size(paths)
  end

  def paths_size(paths)
    paths.each do |path|
      next unless path
      case path
      when /^http:\/\// then
        begin
          url = URI.parse path

          res = timeout @get_file_data_timeout, MogileFS::Timeout do
            s = TCPSocket.new(url.host, url.port)
            s.syswrite("HEAD #{url.request_uri} HTTP/1.0\r\n\r\n")
            s.sysread(4096)
          end
          if cl = /^Content-Length:\s*(\d+)/i.match(res)
            return cl[1].to_i
          end
          next
        rescue MogileFS::Timeout, Errno::ECONNREFUSED,
               EOFError, SystemCallError
          next
        end
      else
        next unless File.exist? path
        return File.size(path)
      end
    end

    nil
  end

  ##
  # Lists keys starting with +prefix+ follwing +after+ up to +limit+.  If
  # +after+ is nil the list starts at the beginning.

  def list_keys(prefix, after = nil, limit = 1000)
    res = begin
      @backend.list_keys(:domain => domain, :prefix => prefix,
                         :after => after, :limit => limit)
    rescue MogileFS::Backend::NoneMatchError
      return nil
    end

    keys = (1..res['key_count'].to_i).map { |i| res["key_#{i}"] }

    return keys, res['next_after']
  end

end

