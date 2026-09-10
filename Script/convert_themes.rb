#!/usr/bin/env ruby
# Compatibility entry point for the shared RGBA-aware theme importer.
exec('python3', File.join(__dir__, 'convert_themes.py'), *ARGV)
