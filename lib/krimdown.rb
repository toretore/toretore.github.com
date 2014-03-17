# encoding: utf-8
require 'kramdown'



module ZFT

  class KramdownWrappedHTMLConverter < ::Kramdown::Converter::Html

    BLOCK_TYPES = %w[alpha beta gamma delta]# epsilon zeta eta heta iota]

    def inner(el, indent)
      result = ''
      indent += @indent
      @stack.push(el)
      el.children.each do |inner_el|
        result << if el.type == :root && inner_el.type != :blank && inner_el.class.category(inner_el) == :block
          "#{' '*indent}<div class=\"block #{inner_el.type} #{BLOCK_TYPES[rand(BLOCK_TYPES.size)]}\">\n#{send(DISPATCHER[inner_el.type], inner_el, indent+1).chomp}\n#{' '*indent}</div>"
        else
          send(DISPATCHER[inner_el.type], inner_el, indent)
        end
      end
      @stack.pop
      result
    end

    def convert_codeblock(el, indent)
      attr = el.attr.dup
      lang = extract_code_language!(attr)
      opts = {line_numbers: nil, css: :class}
      lang = (lang || 'text').to_sym
      result = CodeRay.scan(el.value.chomp, lang).html(opts).chomp
      "#{' '*indent}<pre><code class=\"#{lang}\">#{result}#{' '*indent}</code></pre>\n"
    end

  end

  class KrimdownFilter < ::Nanoc::Filter

    register 'ZFT::KrimdownFilter', :krimdown
    requires 'kramdown'

    # Runs the content through [Kramdown](http://kramdown.rubyforge.org/).
    # Parameters passed to this filter will be passed on to Kramdown.
    #
    # @param [String] content The content to filter
    #
    # @return [String] The filtered content
    def run(content, params={})
      # Get result
      document = ::Kramdown::Document.new(content, params.merge(coderay_line_numbers: nil, coderay_css: 'class', coderay_wrap: 'div', hard_wrap: false, smart_quotes: %w[apos apos quot quot]))
      output, warnings = KramdownWrappedHTMLConverter.convert(document.root, document.options)
      output
    end

  end
end
