require 'bigdecimal'
require 'date'

module Arel
  module Visitors
    class ToSql < Arel::Visitors::Visitor
      ##
      # This is some roflscale crazy stuff.  I'm roflscaling this because
      # building SQL queries is a hotspot.  I will explain the roflscale so that
      # others will not rm this code.
      #
      # In YARV, string literals in a method body will get duped when the byte
      # code is executed.  Let's take a look:
      #
      # > puts RubyVM::InstructionSequence.new('def foo; "bar"; end').disasm
      #
      #   == disasm: <RubyVM::InstructionSequence:foo@<compiled>>=====
      #    0000 trace            8
      #    0002 trace            1
      #    0004 putstring        "bar"
      #    0006 trace            16
      #    0008 leave
      #
      # The `putstring` bytecode will dup the string and push it on the stack.
      # In many cases in our SQL visitor, that string is never mutated, so there
      # is no need to dup the literal.
      #
      # If we change to a constant lookup, the string will not be duped, and we
      # can reduce the objects in our system:
      #
      # > puts RubyVM::InstructionSequence.new('BAR = "bar"; def foo; BAR; end').disasm
      #
      #  == disasm: <RubyVM::InstructionSequence:foo@<compiled>>========
      #  0000 trace            8
      #  0002 trace            1
      #  0004 getinlinecache   11, <ic:0>
      #  0007 getconstant      :BAR
      #  0009 setinlinecache   <ic:0>
      #  0011 trace            16
      #  0013 leave
      #
      # `getconstant` should be a hash lookup, and no object is duped when the
      # value of the constant is pushed on the stack.  Hence the crazy
      # constants below.
      #
      # `matches` and `doesNotMatch` operate case-insensitively via Visitor subclasses
      # specialized for specific databases when necessary.
      #

      WHERE    = ' WHERE '    # :nodoc:
      SPACE    = ' '          # :nodoc:
      COMMA    = ', '         # :nodoc:
      GROUP_BY = ' GROUP BY ' # :nodoc:
      ORDER_BY = ' ORDER BY ' # :nodoc:
      WINDOW   = ' WINDOW '   # :nodoc:
      AND      = ' AND '      # :nodoc:

      DISTINCT = 'DISTINCT'   # :nodoc:

      def initialize connection
        @connection     = connection
        @schema_cache   = connection.schema_cache
        @quoted_tables  = {}
        @quoted_columns = {}
      end

      private

      def visit_Arel_Nodes_DeleteStatement o, collector
        collector << "DELETE FROM "
        collector = visit o.relation, collector
        if o.wheres.any?
          collector << " WHERE "
          inject_join o.wheres, collector, AND
        else
          collector
        end
      end

      # FIXME: we should probably have a 2-pass visitor for this
      def build_subselect key, o
        stmt             = Nodes::SelectStatement.new
        core             = stmt.cores.first
        core.froms       = o.relation
        core.wheres      = o.wheres
        core.projections = [key]
        stmt.limit       = o.limit
        stmt.orders      = o.orders
        stmt
      end

      def visit_Arel_Nodes_UpdateStatement o, collector
        if o.orders.empty? && o.limit.nil?
          wheres = o.wheres
        else
          wheres = [Nodes::In.new(o.key, [build_subselect(o.key, o)])]
        end

        collector << "UPDATE "
        collector = visit o.relation, collector
        values = false
        unless o.values.empty?
          values = true
          collector << " SET "
          collector = inject_join o.values, collector, ", "
        end

        unless wheres.empty?
          collector << " " if values
          collector << "WHERE "
          collector = inject_join wheres, collector, " AND "
        end

        collector
      end

      def visit_Arel_Nodes_InsertStatement o
        [
          "INSERT INTO #{visit o.relation}",

          ("(#{o.columns.map { |x|
          quote_column_name x.name
        }.join ', '})" unless o.columns.empty?),

          (visit o.values if o.values),
        ].compact.join ' '
      end

      def visit_Arel_Nodes_Exists o
        "EXISTS (#{visit o.expressions})#{
          o.alias ? " AS #{visit o.alias}" : ''}"
      end

      def visit_Arel_Nodes_Casted o, collector
        collector << quoted(o.val, o.attribute).to_s
      end

      def visit_Arel_Nodes_Quoted o, collector
        collector << quoted(o.expr, nil).to_s
      end

      def visit_Arel_Nodes_True o, collector
        collector << "TRUE"
      end

      def visit_Arel_Nodes_False o, collector
        collector << "FALSE"
      end

      def table_exists? name
        @schema_cache.table_exists? name
      end

      def column_for attr
        return unless attr
        name    = attr.name.to_s
        table   = attr.relation.table_name

        return nil unless table_exists? table

        column_cache(table)[name]
      end

      def column_cache(table)
        @schema_cache.columns_hash(table)
      end

      def visit_Arel_Nodes_Values o
        "VALUES (#{o.expressions.zip(o.columns).map { |value, attr|
          if Nodes::SqlLiteral === value
            visit value
          else
            quote(value, attr && column_for(attr))
          end
        }.join ', '})"
      end

      def visit_Arel_Nodes_SelectStatement o, collector
        if o.with
          collector = visit o.with, collector
          collector << SPACE
        end

        collector = o.cores.inject(collector) { |c,x|
          visit_Arel_Nodes_SelectCore(x, c)
        }

        unless o.orders.empty?
          collector << SPACE
          collector << ORDER_BY
          len = o.orders.length - 1
          o.orders.each_with_index { |x, i|
            collector = visit(x, collector)
            collector << COMMA unless len == i
          }
        end

        collector = maybe_visit o.limit, collector
        collector = maybe_visit o.offset, collector
        collector = maybe_visit o.lock, collector

        collector
      end

      def visit_Arel_Nodes_SelectCore o, collector
        collector << "SELECT"

        if o.top
          collector << " "
          collector = visit o.top, collector
        end

        if o.set_quantifier
          collector << " "
          collector = visit o.set_quantifier, collector
        end

        unless o.projections.empty?
          collector << SPACE
          len = o.projections.length - 1
          o.projections.each_with_index do |x, i|
            collector = visit(x, collector)
            collector << COMMA unless len == i
          end
        end

        if o.source && !o.source.empty?
          collector << " FROM "
          collector = visit o.source, collector
        end

        unless o.wheres.empty?
          collector << WHERE
          len = o.wheres.length - 1
          o.wheres.each_with_index do |x, i|
            collector = visit(x, collector)
            collector << AND unless len == i
          end
        end

        unless o.groups.empty?
          collector << GROUP_BY
          len = o.groups.length - 1
          o.groups.each_with_index do |x, i|
            collector = visit(x, collector)
            collector << COMMA unless len == i
          end
        end

        if o.having
          collector << " "
          collector = visit(o.having, collector)
        end

        unless o.windows.empty?
          collector << WINDOW
          len = o.windows.length - 1
          o.windows.each_with_index do |x, i|
            collector = visit(x, collector)
            collector << COMMA unless len == i
          end
        end

        collector
      end

      def visit_Arel_Nodes_Bin o
        visit o.expr
      end

      def visit_Arel_Nodes_Distinct o
        DISTINCT
      end

      def visit_Arel_Nodes_DistinctOn o, collector
        raise NotImplementedError, 'DISTINCT ON not implemented for this db'
      end

      def visit_Arel_Nodes_With o
        "WITH #{o.children.map { |x| visit x }.join(', ')}"
      end

      def visit_Arel_Nodes_WithRecursive o, collector
        collector << "WITH RECURSIVE "
        inject_join o.children, collector, ', '
      end

      def visit_Arel_Nodes_Union o, collector
        collector << "( "
        infix_value(o, collector, " UNION ") << " )"
      end

      def visit_Arel_Nodes_UnionAll o
        "( #{visit o.left} UNION ALL #{visit o.right} )"
      end

      def visit_Arel_Nodes_Intersect o
        "( #{visit o.left} INTERSECT #{visit o.right} )"
      end

      def visit_Arel_Nodes_Except o, collector
        "( #{visit o.left} EXCEPT #{visit o.right} )"
      end

      def visit_Arel_Nodes_NamedWindow o, collector
        collector << quote_column_name(o.name)
        collector << " AS "
        visit_Arel_Nodes_Window o, collector
      end

      def visit_Arel_Nodes_Window o, collector
        collector << "("
        if o.orders.any?
          collector << "ORDER BY "
          collector = inject_join o.orders, collector, ", "
        end

        if o.framing
          collector = visit o.framing, collector
        end

        collector << ")"
      end

      def visit_Arel_Nodes_Rows o, collector
        if o.expr
          collector << "ROWS "
          visit o.expr, collector
        else
          collector << "ROWS"
        end
      end

      def visit_Arel_Nodes_Range o, collector
        if o.expr
          collector << "RANGE "
          visit o.expr, collector
        else
          collector << "RANGE"
        end
      end

      def visit_Arel_Nodes_Preceding o, collector
        collector = if o.expr
                      visit o.expr, collector
                    else
                      collector << "UNBOUNDED"
                    end

        collector << " PRECEDING"
      end

      def visit_Arel_Nodes_Following o, collector
        collector = if o.expr
                      visit o.expr, collector
                    else
                      collector << "UNBOUNDED"
                    end

        collector << " FOLLOWING"
      end

      def visit_Arel_Nodes_CurrentRow o, collector
        collector << "CURRENT ROW"
      end

      def visit_Arel_Nodes_Over o
        case o.right
          when nil
            "#{visit o.left} OVER ()"
          when Arel::Nodes::SqlLiteral
            "#{visit o.left} OVER #{visit o.right}"
          when String, Symbol
            "#{visit o.left} OVER #{quote_column_name o.right.to_s}"
          else
            "#{visit o.left} OVER #{visit o.right}"
        end
      end

      def visit_Arel_Nodes_Having o
        "HAVING #{visit o.expr}"
      end

      def visit_Arel_Nodes_Offset o
        "OFFSET #{visit o.expr}"
      end

      def visit_Arel_Nodes_Limit o, collector
        collector << "LIMIT "
        visit o.expr, collector
      end

      # FIXME: this does nothing on most databases, but does on MSSQL
      def visit_Arel_Nodes_Top o, collector
        collector
      end

      def visit_Arel_Nodes_Lock o, collector
        visit o.expr, collector
      end

      def visit_Arel_Nodes_Grouping o, collector
        collector << "("
        visit(o.expr, collector) << ")"
      end

      def visit_Arel_SelectManager o, collector
        collector << "(#{o.to_sql.rstrip})"
      end

      def visit_Arel_Nodes_Ascending o, collector
        visit(o.expr, collector) << " ASC"
      end

      def visit_Arel_Nodes_Descending o, collector
        visit(o.expr, collector) << " DESC"
      end

      def visit_Arel_Nodes_Group o, collector
        visit o.expr, collector
      end

      def visit_Arel_Nodes_NamedFunction o, collector
        collector << o.name
        collector << "("
        collector << "DISTINCT " if o.distinct
        collector = inject_join(o.expressions, collector, ", ") << ")"
        if o.alias
          collector << " AS "
          visit o.alias, collector
        else
          collector
        end
      end

      def visit_Arel_Nodes_Extract o
        "EXTRACT(#{o.field.to_s.upcase} FROM #{visit o.expr})#{o.alias ? " AS #{visit o.alias}" : ''}"
      end

      def visit_Arel_Nodes_Count o, collector
        aggregate "COUNT", o, collector
      end

      def visit_Arel_Nodes_Sum o, collector
        aggregate "SUM", o, collector
      end

      def visit_Arel_Nodes_Max o, collector
        aggregate "MAX", o, collector
      end

      def visit_Arel_Nodes_Min o, collector
        aggregate "MIN", o, collector
      end

      def visit_Arel_Nodes_Avg o, collector
        aggregate "AVG", o, collector
      end

      def visit_Arel_Nodes_TableAlias o, collector
        collector = visit o.relation, collector
        collector << " "
        collector << quote_table_name(o.name)
      end

      def visit_Arel_Nodes_Between o, collector
        collector = visit o.left, collector
        collector << " BETWEEN "
        visit o.right, collector
      end

      def visit_Arel_Nodes_GreaterThanOrEqual o, collector
        collector = visit o.left, collector
        collector << " >= "
        visit o.right, collector
      end

      def visit_Arel_Nodes_GreaterThan o, collector
        collector = visit o.left, collector
        collector << " > "
        visit o.right, collector
      end

      def visit_Arel_Nodes_LessThanOrEqual o, collector
        collector = visit o.left, collector
        collector << " <= "
        visit o.right, collector
      end

      def visit_Arel_Nodes_LessThan o, collector
        collector = visit o.left, collector
        collector << " < "
        visit o.right, collector
      end

      def visit_Arel_Nodes_Matches o, collector
        collector = visit o.left, collector
        collector << " LIKE "
        visit o.right, collector
      end

      def visit_Arel_Nodes_DoesNotMatch o, collector
        collector = visit o.left, collector
        collector << " NOT LIKE "
        visit o.right, collector
      end

      def visit_Arel_Nodes_JoinSource o, collector
        if o.left
          collector = visit o.left, collector
          collector << " "
        end
        if o.right.any?
          collector = inject_join o.right, collector, ' '
        end
        collector
      end

      def visit_Arel_Nodes_Regexp o, collector
        raise NotImplementedError, '~ not implemented for this db'
      end

      def visit_Arel_Nodes_NotRegexp o, collector
        raise NotImplementedError, '!~ not implemented for this db'
      end

      def visit_Arel_Nodes_StringJoin o, collector
        visit o.left, collector
      end

      def visit_Arel_Nodes_FullOuterJoin o
        "FULL OUTER JOIN #{visit o.left} #{visit o.right}"
      end

      def visit_Arel_Nodes_OuterJoin o, collector
        collector << "LEFT OUTER JOIN "
        collector = visit o.left, collector
        collector << " "
        visit o.right, collector
      end

      def visit_Arel_Nodes_RightOuterJoin o
        "RIGHT OUTER JOIN #{visit o.left} #{visit o.right}"
      end

      def visit_Arel_Nodes_InnerJoin o, collector
        collector << "INNER JOIN "
        collector = visit o.left, collector
        if o.right
          collector << SPACE
          visit(o.right, collector)
        else
          collector
        end
      end

      def visit_Arel_Nodes_On o, collector
        collector << "ON "
        visit o.expr, collector
      end

      def visit_Arel_Nodes_Not o, collector
        collector << "NOT ("
        visit(o.expr, collector) << ")"
      end

      def visit_Arel_Table o, collector
        if o.table_alias
          collector << "#{quote_table_name o.name} #{quote_table_name o.table_alias}"
        else
          collector << quote_table_name(o.name)
        end
      end

      def visit_Arel_Nodes_In o, collector
        if Array === o.right && o.right.empty?
          collector << '1=0'
        else
          collector = visit o.left, collector
          collector << " IN ("
          visit(o.right, collector) << ")"
        end
      end

      def visit_Arel_Nodes_NotIn o, collector
        if Array === o.right && o.right.empty?
          collector << '1=1'
        else
          collector = visit o.left, collector
          collector << " NOT IN ("
          collector = visit o.right, collector
          collector << ")"
        end
      end

      def visit_Arel_Nodes_And o, collector
        inject_join o.children, collector, " AND "
      end

      def visit_Arel_Nodes_Or o, collector
        collector = visit o.left, collector
        collector << " OR "
        visit o.right, collector
      end

      def visit_Arel_Nodes_Assignment o, collector
        case o.right
        when Arel::Nodes::UnqualifiedColumn, Arel::Attributes::Attribute
          collector = visit o.left, collector
          collector << " = "
          visit o.right, collector
        else
          collector = visit o.left, collector
          collector << " = "
          collector << quote(o.right, column_for(o.left)).to_s
        end
      end

      def visit_Arel_Nodes_Equality o, collector
        right = o.right

        collector = visit o.left, collector

        if right.nil?
          collector << " IS NULL"
        else
          collector << " = "
          visit right, collector
        end
      end

      def visit_Arel_Nodes_NotEqual o, collector
        right = o.right

        collector = visit o.left, collector

        if right.nil?
          collector << " IS NOT NULL"
        else
          collector << " != "
          visit right, collector
        end
      end

      def visit_Arel_Nodes_As o, collector
        collector = visit o.left, collector
        collector << " AS "
        visit o.right, collector
      end

      def visit_Arel_Nodes_UnqualifiedColumn o, collector
        collector << "#{quote_column_name o.name}"
        collector
      end

      def visit_Arel_Attributes_Attribute o, collector
        join_name = o.relation.table_alias || o.relation.name
        collector << "#{quote_table_name join_name}.#{quote_column_name o.name}"
      end
      alias :visit_Arel_Attributes_Integer :visit_Arel_Attributes_Attribute
      alias :visit_Arel_Attributes_Float :visit_Arel_Attributes_Attribute
      alias :visit_Arel_Attributes_Decimal :visit_Arel_Attributes_Attribute
      alias :visit_Arel_Attributes_String :visit_Arel_Attributes_Attribute
      alias :visit_Arel_Attributes_Time :visit_Arel_Attributes_Attribute
      alias :visit_Arel_Attributes_Boolean :visit_Arel_Attributes_Attribute

      def literal o, collector; collector << o.to_s; end

      alias :visit_Arel_Nodes_BindParam  :literal
      alias :visit_Arel_Nodes_SqlLiteral :literal
      alias :visit_Bignum                :literal
      alias :visit_Fixnum                :literal

      def quoted o, a
        quote(o, column_for(a))
      end

      def unsupported o
        raise "unsupported: #{o.class.name}"
      end

      alias :visit_ActiveSupport_Multibyte_Chars :unsupported
      alias :visit_ActiveSupport_StringInquirer  :unsupported
      alias :visit_BigDecimal                    :unsupported
      alias :visit_Class                         :unsupported
      alias :visit_Date                          :unsupported
      alias :visit_DateTime                      :unsupported
      alias :visit_FalseClass                    :unsupported
      alias :visit_Float                         :unsupported
      alias :visit_Hash                          :unsupported
      alias :visit_NilClass                      :unsupported
      alias :visit_String                        :unsupported
      alias :visit_Symbol                        :unsupported
      alias :visit_Time                          :unsupported
      alias :visit_TrueClass                     :unsupported

      def visit_Arel_Nodes_InfixOperation o, collector
        collector = visit o.left, collector
        collector << " #{o.operator} "
        visit o.right, collector
      end

      alias :visit_Arel_Nodes_Addition       :visit_Arel_Nodes_InfixOperation
      alias :visit_Arel_Nodes_Subtraction    :visit_Arel_Nodes_InfixOperation
      alias :visit_Arel_Nodes_Multiplication :visit_Arel_Nodes_InfixOperation
      alias :visit_Arel_Nodes_Division       :visit_Arel_Nodes_InfixOperation

      def visit_Array o, collector
        inject_join o, collector, ", "
      end

      def quote value, column = nil
        return value if Arel::Nodes::SqlLiteral === value
        @connection.quote value, column
      end

      def quote_table_name name
        return name if Arel::Nodes::SqlLiteral === name
        @quoted_tables[name] ||= @connection.quote_table_name(name)
      end

      def quote_column_name name
        @quoted_columns[name] ||= Arel::Nodes::SqlLiteral === name ? name : @connection.quote_column_name(name)
      end

      def maybe_visit thing, collector
        return collector unless thing
        collector << " "
        visit thing, collector
      end

      def inject_join list, collector, join_str
        len = list.length - 1
        list.each_with_index.inject(collector) { |c, (x,i)|
          if i == len
            visit x, c
          else
            visit(x, c) << join_str
          end
        }
      end

      def infix_value o, collector, value
        collector = visit o.left, collector
        collector << " UNION "
        visit o.right, collector
      end

      def aggregate name, o, collector
        collector << "#{name}("
        if o.distinct
          collector << "DISTINCT "
        end
        collector = inject_join(o.expressions, collector, ", ") << ")"
        if o.alias
          collector << " AS "
          visit o.alias, collector
        else
          collector
        end
      end
    end
  end
end
