#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetch a broad set of TextMate grammars into AetherOracle/resources/Syntax/grammars/
# and emit the extension→scopeName registry (textmate_languages.yml).
#
# Sources (both are the standard TextMate grammar format textpow interprets):
#   • official TextMate bundles (XML .plist / .tmLanguage) — classic languages
#   • microsoft/vscode grammars (.tmLanguage.json) — modern languages
#
# Each grammar is saved under its own `scopeName`; the registry is DERIVED from
# each grammar's declared `fileTypes`, so extension→grammar stays authoritative.

require 'json'
require 'yaml'
require 'open-uri'
require 'fileutils'

$LOAD_PATH.unshift(File.expand_path('../AetherOracle/ruby/.vendor_bundle/ruby/3.1.0/gems/plist-3.7.2/lib', __dir__))
require 'plist'

DEST = File.expand_path('../AetherOracle/resources/Syntax/grammars', __dir__)
REGISTRY = File.expand_path('../AetherOracle/resources/Syntax/textmate_languages.yml', __dir__)

GRAMMARS = {
  # ---- official TextMate bundles (classic) ----
  'c'              => 'https://raw.githubusercontent.com/textmate/c.tmbundle/master/Syntaxes/C.plist',
  'cpp'            => 'https://raw.githubusercontent.com/textmate/c.tmbundle/master/Syntaxes/C%2B%2B.plist',
  'css'            => 'https://raw.githubusercontent.com/textmate/css.tmbundle/master/Syntaxes/CSS.plist',
  'diff'           => 'https://raw.githubusercontent.com/textmate/diff.tmbundle/master/Syntaxes/Diff.plist',
  'html'           => 'https://raw.githubusercontent.com/textmate/html.tmbundle/master/Syntaxes/HTML.plist',
  'java'           => 'https://raw.githubusercontent.com/textmate/java.tmbundle/master/Syntaxes/Java.plist',
  'javascript'     => 'https://raw.githubusercontent.com/textmate/javascript.tmbundle/master/Syntaxes/JavaScript.plist',
  'json'           => 'https://raw.githubusercontent.com/textmate/json.tmbundle/master/Syntaxes/JSON.tmLanguage',
  'latex'          => 'https://raw.githubusercontent.com/textmate/latex.tmbundle/master/Syntaxes/LaTeX.plist',
  'makefile'       => 'https://raw.githubusercontent.com/textmate/make.tmbundle/master/Syntaxes/Makefile.plist',
  'markdown'       => 'https://raw.githubusercontent.com/textmate/markdown.tmbundle/master/Syntaxes/Markdown.tmLanguage',
  'objective-c'    => 'https://raw.githubusercontent.com/textmate/objective-c.tmbundle/master/Syntaxes/Objective-C.tmLanguage',
  'perl'           => 'https://raw.githubusercontent.com/textmate/perl.tmbundle/master/Syntaxes/Perl.plist',
  'php'            => 'https://raw.githubusercontent.com/textmate/php.tmbundle/master/Syntaxes/PHP.plist',
  'python'         => 'https://raw.githubusercontent.com/textmate/python.tmbundle/master/Syntaxes/Python.tmLanguage',
  'ruby'           => 'https://raw.githubusercontent.com/textmate/ruby.tmbundle/master/Syntaxes/Ruby.plist',
  'sql'            => 'https://raw.githubusercontent.com/textmate/sql.tmbundle/master/Syntaxes/SQL.plist',
  'xml'            => 'https://raw.githubusercontent.com/textmate/xml.tmbundle/master/Syntaxes/XML.plist',
  'yaml'           => 'https://raw.githubusercontent.com/textmate/yaml.tmbundle/master/Syntaxes/YAML.tmLanguage',
  'bash'           => 'https://raw.githubusercontent.com/textmate/shellscript.tmbundle/master/Syntaxes/Shell-Unix-Bash.tmLanguage',
  'erlang'         => 'https://raw.githubusercontent.com/textmate/erlang.tmbundle/master/Syntaxes/Erlang.plist',
  'haskell'        => 'https://raw.githubusercontent.com/textmate/haskell.tmbundle/master/Syntaxes/Haskell.plist',
  'lisp'           => 'https://raw.githubusercontent.com/textmate/lisp.tmbundle/master/Syntaxes/Lisp.plist',
  'lua'            => 'https://raw.githubusercontent.com/textmate/lua.tmbundle/master/Syntaxes/Lua.plist',
  'scala'          => 'https://raw.githubusercontent.com/textmate/scala.tmbundle/master/Syntaxes/Scala.tmLanguage',
  'coffeescript'   => 'https://raw.githubusercontent.com/textmate/coffee-script.tmbundle/master/Syntaxes/CoffeeScript.tmLanguage',
  # ---- microsoft/vscode (modern) ----
  'typescript'     => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/typescript-basics/syntaxes/TypeScript.tmLanguage.json',
  'rust'           => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/rust/syntaxes/rust.tmLanguage.json',
  'swift'          => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/swift/syntaxes/swift.tmLanguage.json',
  'go'             => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/go/syntaxes/go.tmLanguage.json',
  'csharp'         => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/csharp/syntaxes/csharp.tmLanguage.json',
  'clojure'        => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/clojure/syntaxes/clojure.tmLanguage.json',
  'dart'           => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/dart/syntaxes/dart.tmLanguage.json',
  'dockerfile'     => 'https://raw.githubusercontent.com/microsoft/vscode/main/extensions/docker/syntaxes/docker.tmLanguage.json',
}.freeze

# VSCode grammars carry no `fileTypes` (language↔extension lives in the extension's
# package.json), so their extension associations are declared here.
MANUAL_FILETYPES = {
  'source.ts'         => %w[ts tsx mts cts],
  'source.rust'       => %w[rs],
  'source.swift'      => %w[swift],
  'source.go'         => %w[go],
  'source.cs'         => %w[cs csx],
  'source.clojure'    => %w[clj cljs cljc edn],
  'source.dart'       => %w[dart],
  'source.dockerfile' => %w[Dockerfile dockerfile],
}.freeze

# Resolve ambiguous extensions (e.g. `c`/`C` colliding between C and C++) to the
# most common interpretation.
OVERRIDES = {
  'c' => 'source.c',
  'h' => 'source.c',
}.freeze

# Hand-written grammars shipped in-tree (no upstream fetch). Their extension →
# scopeName associations are merged into the registry so a re-fetch keeps them.
LOCAL_GRAMMARS = {
  'source.ini' => %w[ini cfg conf properties desktop editorconfig],
}.freeze

def parse(raw)
  return JSON.parse(raw) if raw.lstrip.start_with?('{', '[')
  return Plist.parse_xml(raw) if raw.lstrip.start_with?('<?xml', '<plist', '<!DOCTYPE')

  nil
end

FileUtils.mkdir_p(DEST)
registry = {}
failures = []

GRAMMARS.each do |name, url|
  raw = URI.open(url, read_timeout: 20).read
  table = parse(raw)
  unless table && table['scopeName']
    failures << "#{name}: no scopeName (#{table&.class})"
    next
  end
  scope = table['scopeName']
  file = File.join(DEST, "#{scope}.tmLanguage")
  File.binwrite(file, raw)
  file_types = (table['fileTypes'] || []) + MANUAL_FILETYPES.fetch(scope, [])
  file_types.each { |ext| registry[ext.downcase] = scope }
  puts "OK  #{name.ljust(14)} -> #{scope}  (#{file_types.join(', ')})"
rescue StandardError => e
  failures << "#{name}: #{e.class}: #{e.message}"
end

# Stable, readable YAML.
header = "# Auto-generated by Script/fetch_textmate_grammars.rb\n" \
         "# extension → TextMate scopeName (grammar file lives at Syntax/grammars/<scopeName>.tmLanguage)\n"
OVERRIDES.each { |ext, scope| registry[ext] = scope }
LOCAL_GRAMMARS.each { |scope, exts| exts.each { |ext| registry[ext.downcase] = scope } }
body = registry.keys.sort.map { |ext| "#{ext}: #{registry[ext]}" }.join("\n")
File.write(REGISTRY, header + body + "\n")

puts "\n--- registry: #{registry.size} extensions, #{registry.values.uniq.size} grammars"
puts "--- written to #{REGISTRY}"
unless failures.empty?
  puts "\nFAILURES:"
  failures.each { |f| puts "  ✗ #{f}" }
  exit 1
end