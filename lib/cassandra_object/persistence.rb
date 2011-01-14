module CassandraObject
  module Persistence
    extend ActiveSupport::Concern
    included do
      class_inheritable_writer :write_consistency
      class_inheritable_writer :read_consistency
    end

    VALID_READ_CONSISTENCY_LEVELS = [:one, :quorum, :all]
    VALID_WRITE_CONSISTENCY_LEVELS = VALID_READ_CONSISTENCY_LEVELS

    module ClassMethods
      def consistency_levels(levels)
        if levels.has_key?(:write)
          unless valid_write_consistency_level?(levels[:write])
            raise ArgumentError, "Invalid write consistency level. Valid levels are: #{VALID_WRITE_CONSISTENCY_LEVELS.inspect}. You gave me #{levels[:write].inspect}"
          end
          self.write_consistency = levels[:write]
        end

        if levels.has_key?(:read)
          unless valid_read_consistency_level?(levels[:read])
            raise ArgumentError, "Invalid read consistency level. Valid levels are #{VALID_READ_CONSISTENCY_LEVELS.inspect}. You gave me #{levels[:write].inspect}"
          end
          self.read_consistency = levels[:read]
        end
      end

      def write_consistency
        read_inheritable_attribute(:write_consistency) || :quorum
      end

      def read_consistency
        read_inheritable_attribute(:read_consistency) || :quorum
      end

      def get(key, options = {})
        multi_get([key], options).values.first
      end

      def multi_get(keys, options = {})
        options = {:consistency => self.read_consistency, :limit => 100}.merge(options)
        unless valid_read_consistency_level?(options[:consistency])
          raise ArgumentError, "Invalid read consistency level: '#{options[:consistency]}'. Valid options are [:quorum, :one]"
        end

        attribute_results = ActiveSupport::Notifications.instrument("multi_get.cassandra_object", :keys => keys) do
          connection.multi_get(column_family, keys.map(&:to_s), :count=>options[:limit], :consistency=>consistency_for_thrift(options[:consistency]))
        end

        attribute_results.inject(ActiveSupport::OrderedHash.new) do |memo, (key, attributes)|
          if attributes.empty?
            memo[key] = nil
          else
            memo[parse_key(key)] = instantiate(key, attributes)
          end
          memo
        end
      end

      def remove(key)
        ActiveSupport::Notifications.instrument("remove.cassandra_object", :key => key) do
          connection.remove(column_family, key.to_s, :consistency => write_consistency_for_thrift)
        end
      end

      def delete_all
        connection.truncate!(column_family)
      end

      def all(keyrange = ''..'', options = {})
        count = options[:limit] || 100
        results = ActiveSupport::Notifications.instrument("get_range.cassandra_object", :start => keyrange.first, :finish => keyrange.last, :count => count) do
          connection.get_range(column_family, :start => keyrange.first, :finish => keyrange.last, :count => count)
        end
        keys = results.map(&:key)
        keys.map {|key| get(key) }
      end

      def first(keyrange = ''..'', options = {})
        all(keyrange, options.merge(:limit=>1)).first
      end

      def create(attributes)
        new(attributes).tap do |object|
          object.save
        end
      end

      def write(key, attributes, schema_version)
        key.tap do |key|
          attributes = encode_columns_hash(attributes, schema_version)
          ActiveSupport::Notifications.instrument("insert.cassandra_object", :key => key, :attributes => attributes) do
            connection.insert(column_family, key.to_s, attributes, :consistency => write_consistency_for_thrift)
          end
        end
      end

      def instantiate(key, attributes)
        # remove any attributes we don't know about. we would do this earlier, but we want to make such
        #  attributes available to migrations
        attributes.delete_if{|k,_| !model_attributes.keys.include?(k)}
        allocate.tap do |object|
          object.instance_variable_set("@schema_version", attributes.delete('schema_version'))
          object.instance_variable_set("@key", parse_key(key))
          object.instance_variable_set("@attributes", decode_columns_hash(attributes).with_indifferent_access)
        end
      end

      def encode_columns_hash(attributes, schema_version)
        attributes.inject(Hash.new) do |memo, (column_name, value)|
          memo[column_name.to_s] = model_attributes[column_name].converter.encode(value)
          memo
        end.merge({"schema_version" => schema_version.to_s})
      end

      def decode_columns_hash(attributes)
        attributes.inject(Hash.new) do |memo, (column_name, value)|
          memo[column_name.to_s] = model_attributes[column_name].converter.decode(value)
          memo
        end
      end
      
      def column_family_configuration
        [{:Name=>column_family, :CompareWith=>"UTF8Type"}]
      end

      protected
      def valid_read_consistency_level?(level)
        !!VALID_READ_CONSISTENCY_LEVELS.include?(level)
      end

      def valid_write_consistency_level?(level)
        !!VALID_WRITE_CONSISTENCY_LEVELS.include?(level)
      end

      def write_consistency_for_thrift
        consistency_for_thrift(write_consistency)
      end

      def read_consistency_for_thrift
        consistency_for_thrift(read_consistency)
      end

      def consistency_for_thrift(consistency)
        {
          :one    => Cassandra::Consistency::ONE, 
          :quorum => Cassandra::Consistency::QUORUM,
          :all    => Cassandra::Consistency::ALL
        }[consistency]
      end
    end

    module InstanceMethods
      def save
        _run_save_callbacks do
          create_or_update
        end
      end
      
      def create_or_update
        result = persisted? ? update : create
        result != false
      end
      
      def create
        _run_create_callbacks do
          @key ||= self.class.next_key(self)
          _write
          @persisted = true
          @key
        end
      end
      
      def update
        _run_update_callbacks do
          _write
        end
      end
      
      def _write
        changed_attributes = changed.inject({}) { |h, n| h[n] = read_attribute(n); h }
        self.class.write(key, changed_attributes, schema_version)
      end

      def new_record?
        !@persisted
      end

      def destroyed?
        @destroyed
      end

      def persisted?
        @persisted && !destroyed?
      end

      def destroy
        _run_destroy_callbacks do 
          self.class.remove(key)
          @destroyed = true
          freeze
        end
      end
      
      def reload
        self.class.get(self.key)
      end
      
    end
  end
end
