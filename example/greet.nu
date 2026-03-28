#!/usr/bin/env nu

# Greet someone (or the world).
def main [
  name?: string  # Who to greet (default: "world")
] {
  let target = ($name | default "world")
  print $"Hello, ($target)! 👋"
}
