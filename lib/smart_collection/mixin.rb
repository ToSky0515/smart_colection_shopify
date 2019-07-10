module SmartCollection
  class Mixin < Module
    module ClassMethods
      def smart_collection_mixin
        @__smart_collection_mixin ||= ancestors.find do |x|
          x.instance_of? Mixin
        end
      end
    end

    attr_reader :config

    def initialize raw_config
      @raw_config = raw_config
    end

    def uncached_scope owner
      scopes = @config.scopes_proc.(owner)
=begin
SELECT
    products.*
FROM
    products
WHERE
    id IN (SELECT
            id
        FROM
            ((SELECT
                `products`.`id`
            FROM
                `products`
            WHERE
                `products`.`id` IN (1 , 2, 3)) UNION (SELECT
                `products`.`id`
            FROM
                `products`
            WHERE
                `products`.`id` IN (4 , 5, 6))) AS ids)
=end
      raise unless scopes.all?{|x| x.klass == @config.item_class}
      raise
    end

    def cached_scope owner
      @config.cache_manager.read_scope owner
    end

    def define_association base
      config = @config
      if cache_class = CacheManager.determine_class(@raw_config)
        config.cache_manager = cache_class.new(model: base, config: config)
      end

      mixin_options = {
        name: config.items_name,
        scope: -> owner {
          if owner.new_record?
            uncached_scope(owner)
          else
            cache_manager = config.cache_manager
            unless cache_manager.cache_exists? owner
              owner.update_cache
            end
            cached_scope(owner)
          end
        },
        type: :collection
      }

      case
      when cache_class == SmartCollection::CacheManager::Table
        cached_name = "cached_#{config.items_name}".to_sym
        mixin_options[:preloader] = -> owners {
          owners.reject(&:cache_exists?).each(&:update_cache)
          Associationist.preload(owners, cached_items: config.item_name)
          owners.map do |owner|
            [owner, owner.cached_items.map{|item| item.send(config.item_name)}]
          end.to_h
        }
      end
      base.include Associationist::Mixin.new(mixin_options)
    end

    def expired_scope base
      base.where(base.arel_table[:cache_expires_at].lt(Time.now))
    end

    def define_inverse_association base
      mixin_options = {
        name: @config.inverse_association,
        scope: -> owner {
          expired = base.joins(:cached_items).where(@config.cache_table_name => {item_id: owner.id}).merge(expired_scope base)
          expired.each(&:update_cache)
          base.joins(:cached_items).where(@config.cache_table_name => {item_id: owner.id})
        },
        type: :collection
      }
      @config.item_class.include Associationist::Mixin.new(mixin_options)
    end

    def included base
      @config = config = SmartCollection::Config.new(@raw_config)

      base.include(InstanceMethods)
      base.extend(ClassMethods)

      define_association base
      define_inverse_association base
    end
  end
end
