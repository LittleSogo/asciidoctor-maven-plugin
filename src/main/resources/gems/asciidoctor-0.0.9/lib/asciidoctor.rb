require 'rubygems'
require 'strscan'

$:.unshift(File.dirname(__FILE__))
#$:.unshift(File.join(File.dirname(__FILE__), '..', 'vendor'))

# Public: Methods for parsing Asciidoc input files and rendering documents
# using eRuby templates.
#
# Asciidoc documents comprise a header followed by zero or more sections.
# Sections are composed of blocks of content.  For example:
#
#   Doc Title
#   =========
#
#   SECTION 1
#   ---------
#
#   This is a paragraph block in the first section.
#
#   SECTION 2
#
#   This section has a paragraph block and an olist block.
#
#   1. Item 1
#   2. Item 2
#
# Examples:
#
# Use built-in templates:
#
#   lines = File.readlines("your_file.asc")
#   doc = Asciidoctor::Document.new(lines)
#   html = doc.render
#   File.open("your_file.html", "w+") do |file|
#     file.puts html
#   end
#
# Use custom (Tilt-supported) templates:
#
#   lines = File.readlines("your_file.asc")
#   doc = Asciidoctor::Document.new(lines, :template_dir => 'templates')
#   html = doc.render
#   File.open("your_file.html", "w+") do |file|
#     file.puts html
#   end
module Asciidoctor

  module SafeMode

    # A safe mode level that disables any of the security features enforced
    # by Asciidoctor (Ruby is still subject to its own restrictions).
    UNSAFE = 0;

    # A safe mode level that closely parallels safe mode in AsciiDoc. This value
    # prevents access to files which reside outside of the parent directory of
    # the source file and disables any macro other than the include::[] macro.
    SAFE = 1;

    # A safe mode level that disallows the document from attempting to read files
    # from the file system and including the contents of them into the document.
    # This value disallows use of the include::[] macro and the embedding of
    # binary content (data uri), stylesheets and JavaScripts referenced by the
    # document. (Asciidoctor and trusted extensions may still be allowed to embed
    # trusted content into the document). Since Asciidoctor is aiming for wide
    # adoption, this value is the default and is recommended for server-side
    # deployments.
    SECURE = 10;

    # A planned safe mode level that disallows the use of passthrough macros and
    # prevents the document from setting any known attributes, in addition to all
    # the security features of SafeMode::SECURE
    #
    # Please note that this level is not currently implemented (and therefore not
    # enforced)!
    #PARANOID = 100;

  end

  # The default document type
  # Can influence markup generated by render templates
  DEFAULT_DOCTYPE = 'article'

  # Backend determines the format of the rendered output, default to html5
  DEFAULT_BACKEND = 'html5'

  # Default page widths for calculating absolute widths
  DEFAULT_PAGE_WIDTHS = {
    'docbook' => 425
  }

  LIST_CONTEXTS = [:ulist, :olist, :dlist, :colist]

  NESTABLE_LIST_CONTEXTS = [:ulist, :olist, :dlist]

  ORDERED_LIST_STYLES = [:arabic, :loweralpha, :lowerroman, :upperalpha, :upperroman]

  ORDERED_LIST_MARKER_PATTERNS = {
    :arabic => /\d+[\.>]/,
    :loweralpha => /[a-z]\./,
    :upperalpha => /[A-Z]\./,
    :lowerroman => /[ivx]+\)/,
    :upperroman => /[IVX]+\)/
  }

  LIST_CONTINUATION = '+'

  BLANK_LINES_PATTERN = /^\s*\n/

  LINE_FEED_ENTITY = '&#10;' # or &#x0A;

  REGEXP = {
    # [[Foo]]
    :anchor           => /^\[\[([^\[\]]+)\]\]\s*$/,

    # Foowhatevs [[Bar]]
    :anchor_embedded  => /^(.*?)\s*\[\[([^\[\]]+)\]\]\s*$/,

    # [[ref]] (anywhere inline)
    :anchor_macro     => /\\?\[\[([\w":].*?)\]\]/,

    # matches any block delimiter:
    #   open, listing, example, literal, comment, quote, sidebar, passthrough, table
    # NOTE position the most common blocks towards the front of the pattern
    :any_blk          => %r{^(?:\-\-|(?:\-|=|\.|/|_|\*|\+){4,}|[\|!]={3,})\s*$},

    # optimization when scanning lines for blocks
    # NOTE accessing the first element before calling ord is first Ruby 1.8.7 compat
    :any_blk_ord      => %w(- = . / _ * + | !).map {|c| c[0].ord },

    # :foo: bar
    :attr_assign      => /^:([^:!]+):\s*(.*)\s*$/,

    # {name?value}
    :attr_conditional => /^\s*\{([^\?]+)\?\s*([^\}]+)\s*\}/,

    # +   Attribute values treat lines ending with ' +' as a continuation,
    #     not a line-break as elsewhere in the document, where this is
    #     a forced line break. This should be the same regexp as :line_break,
    #     below, but it gets its own entry because readability ftw, even
    #     though repeating regexps ftl.
    :attr_continue    => /^[[:blank:]]*(.*)[[:blank:]]\+[[:blank:]]*$/,

    # :foo!:
    :attr_delete      => /^:([^:]+)!:\s*$/,

    # An attribute list above a block element
    #
    # Can be strictly positional:
    # [quote, Adam Smith, Wealth of Nations]
    # Or can have name/value pairs
    # [NOTE, caption="Good to know"]
    # Can be defined by an attribute
    # [{lead}]
    :blk_attr_list    => /^\[([\w\{].*)\]$/,

    # attribute list or anchor (indicates a paragraph break)
    :attr_line        => /^\[([\w\{].*|\[[^\[\]]+\])\]$/,

    # attribute reference
    # {foo}
    :attr_ref         => /(\\?)\{(\w|\w[\w\-]*\w)(\\?)\}/,

    # The author info line the appears immediately following the document title
    # John Doe <john@anonymous.com>
    :author_info      => /^\s*([\w\-]+)(?: +([\w\-]+))?(?: +([\w\-]+))?(?: +<([^>]+)>)?\s*$/,

    # [[[Foo]]]  (does not suffer quite the same malady as :anchor, but almost. Allows [ but not ] in internal capture
    :biblio           => /\[\[\[([^\[\]]+)\]\]\]/,

    # callout reference inside literal text
    # <1>
    # special characters will already be replaced, hence their use in the regex
    :callout_render   => /\\?&lt;(\d+)&gt;/,
    # ...but not while scanning
    :callout_scan     => /\\?<(\d+)>/,

    # <1> Foo
    :colist           => /^<?(\d+)> (.*)/,

    # ////
    # comment block
    # ////
    :comment_blk      => %r{^/{4,}\s*$},

    # // (and then whatever)
    :comment          => %r{^//([^/].*|)$},

    # 29
    :digits           => /^\d+$/,

    # foo::  ||  foo::: || foo:::: || foo;;
    # Should be followed by a definition, on the same line...
    # foo:: That which precedes 'bar' (see also, <<bar>>)
    # ...or on a separate line
    # foo::
    #   That which precedes 'bar' (see also, <<bar>>)
    # The term may be an attribute reference
    # {term_foo}:: {def_foo}
    :dlist            => /^\s*(.*?)(:{2,4}|;;)(?:[[:blank:]]+(.*))?$/,
    :dlist_siblings   => {
                           # (?:.*?[^:])? - a non-capturing group which grabs longest sequence of characters that doesn't end w/ colon
                           '::' => /^\s*((?:.*[^:])?)(::)(?:[[:blank:]]+(.*))?$/,
                           ':::' => /^\s*((?:.*[^:])?)(:::)(?:[[:blank:]]+(.*))?$/,
                           '::::' => /^\s*((?:.*[^:])?)(::::)(?:[[:blank:]]+(.*))?$/,
                           ';;' => /^\s*(.*)(;;)(?:[[:blank:]]+(.*))?$/
                         },
    # ====
    :example          => /^={4,}\s*$/,

    # image::filename.png[Caption]
    :image_blk        => /^image::(\S+?)\[(.*?)\]$/,

    # image:filename.png[Alt]
    :image_macro      => /\\?image:([^\[]+)(?:\[([^\]]*)\])/,

    # whitespace at the beginning of the line
    :leading_blanks   => /^([[:blank:]]*)/,

    # +   From the Asciidoc User Guide: "A plus character preceded by at
    #     least one space character at the end of a non-blank line forces
    #     a line break. It generates a line break (br) tag for HTML outputs.
    #
    # +      (would not match because there's no space before +)
    #  +     (would match and capture '')
    # Foo +  (would and capture 'Foo')
    :line_break       => /^(.*)[[:blank:]]\+[[:blank:]]*$/,

    # inline link and some inline link macro
    # FIXME revisit!
    :link_inline      => %r{(^|link:|\s|>|&lt;|[\(\)\]])(\\?https?://[^\[ ]*[^\. \)\[])(?:\[((?:\\\]|[^\]])*?)\])?},

    # inline link macro
    # link:path[label]
    :link_macro       => /\\?link:([^\[ ]+)(?:\[((?:\\\]|[^\]])*?)\])/,

    # ----
    :listing          => /^\-{4,}\s*$/,

    # ....
    :literal          => /^\.{4,}\s*$/,

    # <TAB>Foo  or one-or-more-spaces-or-tabs then whatever
    :lit_par          => /^([[:blank:]]+.*)$/,

    # --
    :open_blk         => /^\-\-\s*$/,

    # . Foo (up to 5 consecutive dots)
    # 1. Foo (arabic, default)
    # a. Foo (loweralpha)
    # A. Foo (upperalpha)
    # i. Foo (lowerroman)
    # I. Foo (upperroman)
    :olist            => /^\s*(\d+\.|[a-z]\.|[ivx]+\)|\.{1,5}) +(.*)$/i,

    # ++++
    :pass             => /^\+{4,}\s*$/,

    # inline passthrough macros
    # +++text+++
    # $$text$$
    # pass:quotes[text]
    :pass_macro       => /\\?(?:(\+{3}|\${2})(.*?)\1|pass:([a-z,]*)\[((?:\\\]|[^\]])*?)\])/m,

    # passthrough macro allowed in value of attribute assignment
    # pass:[text]
    :pass_macro_basic => /^pass:([a-z,]*)\[(.*)\]$/,

    # inline literal passthrough macro
    # `text`
    :pass_lit         => /(^|[^`\w])(\\?`([^`\s]|[^`\s].*?\S)`)(?![`\w])/m,

    # placeholder for extracted passthrough text
    :pass_placeholder => /\x0(\d+)\x0/,

    # ____
    :quote            => /^_{4,}\s*$/,

    # The document revision info line the appears immediately following the
    # document title author info line, if present
    # v1.0, 2013-01-01: Ring in the new year release
    :revision_info    => /^\s*(?:\D*(.*?),)?(?:\s*(.*?))(?:\s*:\s*(.*)\s*)?$/,

    # '''
    :ruler            => /^'{3,}\s*$/,

    # ****
    :sidebar_blk      => /^\*{4,}\s*$/,

    # \' within a word
    :single_quote_esc => /(\w)\\'(\w)/,
    # an alternative if our backend generated single-quoted html/xml attributes
    #:single_quote_esc => /(\w|=)\\'(\w)/,

    # |===
    # |table
    # |===
    :table            => /^\|={3,}\s*$/,

    # !===
    # !table
    # !===
    :table_nested     => /^!={3,}\s*$/,

    # 1*h,2*,^3e
    :table_colspec    => /^(?:(\d+)\*)?([<^>](?:\.[<^>]?)?|(?:[<^>]?\.)?[<^>])?(\d+)?([a-z])?$/,

    # 2.3+<.>m
    # TODO might want to use step-wise scan rather than this mega-regexp
    :table_cellspec => {
      :start => /^[[:blank:]]*(?:(\d+(?:\.\d*)?|(?:\d*\.)?\d+)([*+]))?([<^>](?:\.[<^>]?)?|(?:[<^>]?\.)?[<^>])?([a-z])?\|/,
      :end => /[[:blank:]]+(?:(\d+(?:\.\d*)?|(?:\d*\.)?\d+)([*+]))?([<^>](?:\.[<^>]?)?|(?:[<^>]?\.)?[<^>])?([a-z])?$/
    },

    # .Foo   but not  . Foo or ..Foo
    :blk_title        => /^\.([^\s\.].*)\s*$/,

    # == Foo
    # ^ yields a level 2 title
    #
    # == Foo ==
    # ^ also yields a level 2 title
    #
    # both equivalent to this two-line version:
    # Foo
    # ~~~
    #
    # match[1] is the delimiter, whose length determines the level
    # match[2] is the title itself
    # match[3] is an optional repeat of the delimiter, which is dropped
    :section_title     => /^(={1,5})\s+(\S.*?)\s*(?:\[\[([^\[]+)\]\]\s*)?(\s\1)?$/,

    # does not begin with a dot and has at least one alphanumeric character
    :section_name      => /^((?=.*\w+.*)[^\.].*?)\s*$/,

    # ======  || ------ || ~~~~~~ || ^^^^^^ || ++++++
    :section_underline => /^([=\-~^\+])+\s*$/,

    # * Foo (up to 5 consecutive asterisks)
    # - Foo
    :ulist            => /^ \s* (- | \*{1,5}) \s+ (.*) $/x,

    # inline xref macro
    # <<id,reftext>> (special characters have already been escaped, hence the entity references)
    # xref:id[reftext]
    :xref_macro       => /\\?(?:&lt;&lt;([\w":].*?)&gt;&gt;|xref:([\w":].*?)\[(.*?)\])/m,

    # ifdef::basebackend-html[]
    # ifndef::theme[]
    :ifdef_macro      => /^(ifdef|ifndef)::([^\[]+)\[\]/,

    # endif::theme[]
    # endif::basebackend-html[]
    :endif_macro      => /^endif::/,

    # include::chapter1.ad[]
    :include_macro    => /^\\?include::([^\[]+)\[\]\s*\n?\z/
  }

  ADMONITION_STYLES = ['NOTE', 'TIP', 'IMPORTANT', 'WARNING', 'CAUTION']

  INTRINSICS = Hash.new{|h,k| STDERR.puts "Missing intrinsic: #{k.inspect}"; "{#{k}}"}.merge(
    {
    'startsb'    => '[',
    'endsb'      => ']',
    'brvbar'     => '|',
    'caret'      => '^',
    'asterisk'   => '*',
    'tilde'      => '~',
    'plus'       => '&#43;',
    'apostrophe' => '\'',
    'backslash'  => '\\',
    'backtick'   => '`',
    'empty'      => '',
    'sp'         => ' ',
    'space'      => ' ',
    'two-colons' => '::',
    'two-semicolons' => ';;',
    'nbsp'       => '&#160;',
    'deg'        => '&#176;',
    'zwsp'       => '&#8203;',
    'quot'       => '&#34;',
    'apos'       => '&#39;',
    'lsquo'      => '&#8216;',
    'rsquo'      => '&#8217;',
    'ldquo'      => '&#8220;',
    'rdquo'      => '&#8221;',
    'wj'         => '&#8288;',
    'amp'        => '&',
    'lt'         => '<',
    'gt'         => '>'
    }
  )

  SPECIAL_CHARS = {
    '<' => '&lt;',
    '>' => '&gt;',
    '&' => '&amp;'
  }

  SPECIAL_CHARS_PATTERN = /[#{SPECIAL_CHARS.keys.join}]/

  # unconstrained quotes:: can appear anywhere
  # constrained quotes:: must be bordered by non-word characters
  # NOTE these substituions are processed in the order they appear here and
  # the order in which they are replaced is important
  QUOTE_SUBS = [

    # **strong**
    [:strong, :unconstrained, /\\?(?:\[([^\]]+?)\])?\*\*(.+?)\*\*/m],

    # *strong*
    [:strong, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?\*(\S|\S.*?\S)\*(?=\W|$)/m],

    # ``double-quoted''
    [:double, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?``(\S|\S.*?\S)''(?=\W|$)/m],

    # 'emphasis'
    [:emphasis, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?'(\S|\S.*?\S)'(?=\W|$)/m],

    # `single-quoted'
    [:single, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?`(\S|\S.*?\S)'(?=\W|$)/m],

    # ++monospaced++
    [:monospaced, :unconstrained, /\\?(?:\[([^\]]+?)\])?\+\+(.+?)\+\+/m],

    # +monospaced+
    [:monospaced, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?\+(\S|\S.*?\S)\+(?=\W|$)/m],

    # __emphasis__
    [:emphasis, :unconstrained, /\\?(?:\[([^\]]+?)\])?\_\_(.+?)\_\_/m],

    # _emphasis_
    [:emphasis, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?_(\S|\S.*?\S)_(?=\W|$)/m],

    # ##unquoted##
    [:none, :unconstrained, /\\?(?:\[([^\]]+?)\])?##(.+?)##/m],

    # #unquoted#
    [:none, :constrained, /(^|[^\w;:}])(?:\[([^\]]+?)\])?#(\S|\S.*?\S)#(?=\W|$)/m],

    # ^superscript^
    [:superscript, :unconstrained, /\\?(?:\[([^\]]+?)\])?\^(.+?)\^/m],

    # ~subscript~
    [:subscript, :unconstrained, /\\?(?:\[([^\]]+?)\])?\~(.+?)\~/m]
  ]

  # NOTE in Ruby 1.8.7, [^\\] does not match start of line,
  # so we need to match it explicitly
  # order is significant
  REPLACEMENTS = [
    # (C)
    [/(^|[^\\])\(C\)/, '\1&#169;'], 
    # (R)
    [/(^|[^\\])\(R\)/, '\1&#174;'],
    # (TM)
    [/(^|[^\\])\(TM\)/, '\1&#8482;'],
    # foo -- bar
    [/ -- /, '&#8201;&#8212;&#8201;'],
    # foo--bar
    [/(\w)--(?=\w)/, '\1&#8212;'],
    # ellipsis
    [/(^|[^\\])\.\.\./, '\1&#8230;'],
    # single quotes
    [/(\w)'(\w)/, '\1&#8217;\2'],
    # escaped single quotes
    [/(\w)\\'(\w)/, '\1\'\2'],
    # and so on...
    
    # restore entities; TODO needs cleanup
    [/&amp;(#[a-z0-9]+;)/i, '&\1']
  ]

  # Internal: Prior to invoking Kernel#require, issues a warning urging a
  # manual require if running in a threaded environment.
  #
  # name  - the String name of the library to require.
  #
  # returns nothing
  def self.require_library(name)
    if Thread.list.size > 1
      main_script = "#{name}.rb"
      main_script_path_segment = "/#{name}.rb"
      if !$LOADED_FEATURES.detect {|p| p == main_script || p.end_with?(main_script_path_segment) }.nil?
        return
      else
        warn "WARN: asciidoctor is autoloading '#{name}' in threaded environment. " +
           "The use of an explicit require '#{name}' statement is recommended."
      end
    end
    require name
    nil
  end

  # modules
  require 'asciidoctor/substituters'

  # abstract classes
  require 'asciidoctor/abstract_node'
  require 'asciidoctor/abstract_block'

  # concrete classes
  require 'asciidoctor/attribute_list'
  require 'asciidoctor/backends/base_template'
  require 'asciidoctor/block'
  require 'asciidoctor/callouts'
  require 'asciidoctor/debug'
  require 'asciidoctor/document'
  require 'asciidoctor/errors'
  require 'asciidoctor/inline'
  require 'asciidoctor/lexer'
  require 'asciidoctor/list_item'
  require 'asciidoctor/reader'
  require 'asciidoctor/renderer'
  require 'asciidoctor/section'
  require 'asciidoctor/table'
  require 'asciidoctor/version'
end