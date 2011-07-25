module CassandraObject
  class Types
    module TimeWithZoneType
      def encode(time)
        raise ArgumentError.new("#{self} requires a Time") unless time.kind_of?(Time)
        time.utc.xmlschema(6)
      end
      module_function :encode

      def decode(str)
        return nil if str.empty?
        raise ArgumentError.new("Cannot convert #{str} into a Time") unless str.kind_of?(String) && str.match(TimeType::REGEX)
        Time.xmlschema(str).in_time_zone
      end
      module_function :decode
    end
  end
end