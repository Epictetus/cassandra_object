require 'cassandra_object/associations/one_to_many'
require 'cassandra_object/associations/one_to_one'

module CassandraObject
  module Associations
    extend ActiveSupport::Concern
    
    included do
      class_inheritable_hash :associations
    end

    module ClassMethods
      def column_family_configuration
        super << {:Name=>"#{name}Relationships", :CompareWith=>"UTF8Type", :CompareSubcolumnsWith=>"TimeUUIDType", :ColumnType=>"Super"}
      end
      
      def association(association_name, options= {})
        if options[:unique]
          write_inheritable_hash(:associations, {association_name => OneToOneAssociation.new(association_name, self, options)})
        else
          write_inheritable_hash(:associations, {association_name => OneToManyAssociation.new(association_name, self, options)})
        end
      end
      
      def remove(key)
        begin
          ActiveSupport::Notifications.instrument("remove.cassandra_object", :key => key) do
            connection.remove("#{name}Relationships", key.to_s, :consistency => write_consistency_for_thrift)
          end
        rescue Cassandra::AccessError => e
          raise e unless e.message =~ /Invalid column family/
        end
        super
      end
    end
  end
end
