# Standalone caching forward proxy for apt/debootstrap traffic from the
# QEMU dev VMs (cloudmodel-api-qemu). Deliberately free of Rails/cloudmodel
# dependencies so it can run as a plain detached ruby process:
#
#   ruby apt_cache_daemon.rb <port> <cache_dir>
#
# Only immutable package artifacts (pool/*.deb & friends) are cached —
# repository metadata (dists/, InRelease, Packages) changes over time and
# is hash-verified by apt, so it is always passed through. HTTPS (CONNECT)
# is tunneled uncached.
require 'webrick'
require 'webrick/httpproxy'
require 'fileutils'
require 'uri'

module CloudModel
  module Api
    module Qemu
      class AptCacheDaemon < WEBrick::HTTPProxyServer
        CACHEABLE = /\.(deb|udeb|tar\.(gz|xz|zst)|tgz)\z/

        def self.cacheable? uri
          path = URI.parse(uri).path
          !!(path.include?('/pool/') || path =~ CACHEABLE)
        rescue URI::Error
          false
        end

        # URL → filesystem path inside the cache dir ("host/path" layout);
        # every segment is sanitized, unparseable URIs fall back to treating
        # the whole string as path.
        def self.cache_path cache_dir, uri
          u = (URI.parse(uri) rescue nil)
          host = (u&.host || 'unknown').gsub(/[^a-zA-Z0-9.-]/, '_')
          path = u&.path || uri.sub(%r{\Ahttps?://}, '')

          File.join(cache_dir, host, path.split('/').reject(&:empty?).map { |p|
            p.gsub(/[^a-zA-Z0-9._+~%-]/, '_')
          }.join('/'))
        end

        def initialize cache_dir:, **options
          @cache_dir = cache_dir
          super(**options)
        end

        def proxy_service req, res
          if req.request_method == 'GET' and self.class.cacheable?(req.unparsed_uri)
            path = self.class.cache_path(@cache_dir, req.unparsed_uri)

            if File.file?(path)
              logger.info "HIT  #{req.unparsed_uri}"
              res['content-type'] = 'application/octet-stream'
              res.body = File.open(path, 'rb')
              return
            end

            super

            if res.status == 200 and res.body.is_a?(String) and !res.body.empty?
              logger.info "MISS #{req.unparsed_uri} (#{res.body.bytesize} bytes cached)"
              FileUtils.mkdir_p File.dirname(path)
              tmp = "#{path}.tmp#{Process.pid}"
              File.binwrite tmp, res.body
              File.rename tmp, path
            end
          else
            super
          end
        end
      end
    end
  end
end

if __FILE__ == $0
  port      = (ARGV[0] || 3142).to_i
  cache_dir = ARGV[1] or abort "Usage: ruby apt_cache_daemon.rb <port> <cache_dir>"
  FileUtils.mkdir_p cache_dir

  server = CloudModel::Api::Qemu::AptCacheDaemon.new(
    cache_dir: cache_dir,
    # QEMU's user-mode NAT delivers guest connections to 10.0.2.2 on the
    # workstation's loopback — no need to listen on public interfaces.
    BindAddress: '127.0.0.1',
    Port: port,
    Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
    AccessLog: []
  )
  trap('INT')  { server.shutdown }
  trap('TERM') { server.shutdown }
  server.start
end
