module CassandraObject
  module Types
    class StringType
      def encode(str)
        raise ArgumentError.new("#{self} requires a String") unless str.kind_of?(String)
        str.dup
      end

      def decode(str)
        str
      end
    end
  end
end