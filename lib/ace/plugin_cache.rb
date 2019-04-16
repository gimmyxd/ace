# frozen_string_literal: true

require 'fileutils'
require 'ace/puppet_util'
require 'puppet/configurer'
require 'concurrent'
require 'ace/fork_util'

module ACE
  class PluginCache
    attr_reader :cache_dir_mutex, :cache_dir
    def initialize(environments_cache_dir)
      @cache_dir = environments_cache_dir
      @cache_dir_mutex = Concurrent::ReadWriteLock.new
    end

    def setup
      FileUtils.mkdir_p(cache_dir)
      self
    end

    def with_synced_libdir(environment, certname, &block)
      ForkUtil.isolate do
        ACE::PuppetUtil.isolated_puppet_settings(certname, environment)
        with_synced_libdir_core(environment, &block)
      end
    end

    def with_synced_libdir_core(environment)
      pool = Puppet::Network::HTTP::Pool.new(Puppet[:http_keepalive_timeout])
      Puppet.push_context({
                            http_pool: pool
                          }, "Isolated HTTP Pool")
      libdir = sync_core(environment)
      Puppet.settings[:libdir] = libdir
      $LOAD_PATH << libdir
      yield
    ensure
      FileUtils.remove_dir(libdir)
      pool.close
    end

    # the Puppet[:libdir] will point to a tmp location
    # where the contents from the pluginsync dest is copied
    # too.
    def libdir(plugin_dest)
      tmpdir = Dir.mktmpdir(['plugins', plugin_dest])
      cache_dir_mutex.with_write_lock do
        FileUtils.cp_r(File.join(plugin_dest, '.'), tmpdir)
        FileUtils.touch(tmpdir)
      end
      tmpdir
    end

    def environment_dir(environment)
      environment_dir = File.join(cache_dir, environment)
      cache_dir_mutex.with_write_lock do
        FileUtils.mkdir_p(environment_dir)
        FileUtils.touch(environment_dir)
      end
      environment_dir
    end

    # @returns the tmp libdir directory which will be where
    # Puppet[:libdir] is referenced too
    def sync_core(environment)
      env = Puppet::Node::Environment.remote(environment)
      environments_dir = environment_dir(environment)
      Puppet[:vardir] = File.join(environments_dir)
      Puppet[:confdir] = File.join(environments_dir, 'conf')
      Puppet[:rundir] = File.join(environments_dir, 'run')
      Puppet[:logdir] = File.join(environments_dir, 'log')
      Puppet[:codedir] = File.join(environments_dir, 'code')
      Puppet[:plugindest] = File.join(environments_dir, 'plugins')
      Puppet::Configurer::PluginHandler.new.download_plugins(env)
      libdir(File.join(environments_dir, 'plugins'))
    end
  end
end