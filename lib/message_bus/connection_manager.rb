require 'json' unless defined? ::JSON

class MessageBus::ConnectionManager
  require 'monitor'

  class SynchronizedSet
    include MonitorMixin

    def initialize
      super
      @set = Set.new
    end

    def self.synchronize(methods)
      methods.each do |method|
        define_method method do |*args, &blk|
          synchronize do
            @set.send method,*args,&blk
          end
        end
      end
    end

    synchronize(Set.new.methods - Object.new.methods)

  end

  def initialize(bus = nil)
    @clients = {}
    @subscriptions = {}
    @bus = bus || MessageBus
  end

  def notify_clients(msg)
    begin
      site_subs = @subscriptions[msg.site_id]
      subscription = site_subs[msg.channel] if site_subs

      return unless subscription

      around_filter = @bus.around_client_batch(msg.channel)

      work = lambda do
        subscription.each do |client_id|
          client = @clients[client_id]
          if client && client.allowed?(msg)
            if copy = client.filter(msg)
              begin
                client << copy
              rescue
                # pipe may be broken, move on
              end
              # turns out you can delete from a set while itereating
              remove_client(client)
            end
          end
        end
      end

      if around_filter
        user_ids = subscription.map do |s|
          c = @clients[s]
          c && c.user_id
        end.compact

        if user_ids && user_ids.length > 0
          around_filter.call(msg, user_ids, work)
        end
      else
        work.call
      end

    rescue => e
      MessageBus.logger.error "notify clients crash #{e} : #{e.backtrace}"
    end
  end

  def add_client(client)
    @clients[client.client_id] = client
    @subscriptions[client.site_id] ||= {}
    client.subscriptions.each do |k,v|
      subscribe_client(client, k)
    end
  end

  def remove_client(c)

    return if @clients[c.client_id].connect_time != c.connect_time

    @clients.delete c.client_id
    @subscriptions[c.site_id].each do |k, set|
      set.delete c.client_id
    end
    c.cleanup_timer.cancel if c.cleanup_timer
  end

  def lookup_client(client_id)
    @clients[client_id]
  end

  def subscribe_client(client,channel)
    set = @subscriptions[client.site_id][channel]
    unless set
      set = SynchronizedSet.new
      @subscriptions[client.site_id][channel] = set
    end
    set << client.client_id
  end

  def client_count
    @clients.length
  end

  def stats
    {
      client_count: @clients.length,
      subscriptions: @subscriptions
    }
  end

end
