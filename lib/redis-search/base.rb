class Redis
  # nodoc
  module Search
    autoload :PinYin, 'ruby-pinyin'

    DOT = '.'.freeze

    extend ActiveSupport::Concern

    included do
      cattr_reader :redis_search_options

      before_destroy :redis_search_index_before_destroy
      after_update :redis_search_index_after_update
      after_save :redis_search_index_after_save
    end

    def redis_search_fields_to_hash(ext_fields)
      exts = {}
      ext_fields.each do |f|
        exts[f] = instance_eval(f.to_s)
      end
      exts
    end

    def redis_search_alias_value(field)
      return [] if field.blank? || field == '_was'.freeze
      val = (instance_eval("self.#{field}") || ''.freeze).clone
      return [] unless val.class.in?([String, Array])
      val = val.to_s.split(',') if val.is_a?(String)
      val
    end

    # Rebuild search index with create
    def redis_search_index_create
      opts = {
        title: send(redis_search_options[:title_field]),
        aliases: redis_search_alias_value(redis_search_options[:alias_field]),
        id: id,
        exts: redis_search_fields_to_hash(redis_search_options[:ext_fields]),
        type: redis_search_options[:class_name] || self.class.name,
        condition_fields: redis_search_options[:condition_fields],
        score: send(redis_search_options[:score_field]).to_i
      }

      s = Search::Index.new(opts)
      s.save
      true
    end

    def redis_search_index_delete(titles)
      titles.uniq!
      titles.each do |title|
        next if title.blank?
        Search::Index.remove(id: id, title: title, type: self.class.name)
      end
      true
    end

    def redis_search_index_before_destroy
      titles = redis_search_alias_value(redis_search_options[:alias_field])
      titles << send(redis_search_options[:title_field])

      redis_search_index_delete(titles)
      true
    end

    def redis_search_index_need_reindex
      index_fields_changed = false
      redis_search_options[:ext_fields].each do |f|
        next if f.to_s == 'id'.freeze
        field_method = "saved_change_to_#{f}?"
        if methods.index(field_method.to_sym).nil?
          Redis::Search.warn("#{self.class.name} model reindex on update need #{field_method} method.")
          next
        end

        index_fields_changed = true if instance_eval(field_method)
      end

      begin
        if send("saved_change_to_#{redis_search_options[:title_field]}?")
          index_fields_changed = true
        end

        if send(redis_search_options[:alias_field]) ||
           send("saved_change_to_#{redis_search_options[:title_field]}?")
          index_fields_changed = true
        end
      rescue
      end

      index_fields_changed
    end

    def redis_search_index_after_update
      if redis_search_index_need_reindex
        titles = redis_search_alias_value("#{redis_search_options[:alias_field]}_was")
        titles << send("#{redis_search_options[:title_field]}_was")
        redis_search_index_delete(titles)
      end

      true
    end

    def redis_search_index_after_save
      if redis_search_index_need_reindex || new_record?
        redis_search_index_create
      end
      true
    end

    module ClassMethods
      # Config redis-search index for Model
      # == Params:
      #   title_field   Query field for Search
      #   alias_field   Alias field for search, can accept multi field (String or Array type) it type is String, redis-search will split by comma
      #   ext_fields    What kind fields do you need inlucde to search indexes
      #   score_field   Give a score for search sort, need Integer value, default is `created_at`
      def redis_search(opts = {})
        opts[:title_field] ||= :title
        opts[:alias_field] ||= nil
        opts[:ext_fields] ||= []
        opts[:score_field] ||= :created_at
        opts[:condition_fields] ||= []
        opts[:class_name] ||= nil

        # Add score field to ext_fields
        opts[:ext_fields] += [opts[:score_field]]

        # Add condition fields to ext_fields
        opts[:ext_fields] += opts[:condition_fields] if opts[:condition_fields].is_a?(Array)

        # store Model name to indexed_models for Rake tasks
        Search.indexed_models = [] if Search.indexed_models.nil?
        Search.indexed_models << self

        class_variable_set('@@redis_search_options'.freeze, opts)
      end

      def redis_search_index(opts = {})
        Kernel.warn 'DEPRECATION WARNING: redis_search_index is deprecated, use redis_search instead. '
        redis_search(opts)
      end

      def prefix_match(q, opts = {})
        Redis::Search.complete(self.name, q, opts)
      end

      def redis_search_index_batch_create(batch_size = 1000)
        count = 0
        if ancestors.collect(&:to_s).include?('ActiveRecord::Base'.freeze)
          find_in_batches(batch_size: batch_size) do |items|
            _redis_search_reindex_items(items)
            count += items.count
          end
        elsif included_modules.collect(&:to_s).include?('Mongoid::Document'.freeze)
          self.all.each_slice(batch_size) do |items|
            _redis_search_reindex_items(items)
            count += items.count
          end
        else
          puts 'skiped, not support this ORM in current.'
        end

        count
      end

      private

      def _redis_search_reindex_items(items)
        items.each do |item|
          item.redis_search_index_create
          print DOT
          item = nil
        end
        items = nil
      end
    end
  end
end
