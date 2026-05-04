# Package

version       = "0.1.0"
author        = "nsheep team"
description   = "A centralized Nim package registry + CDN server"
license       = "MIT"
srcDir        = "src"
bin           = @["nsheep"]
namedBin      = {"nsheep/fetcher": "nsheep-fetcher"}.toTable()

# Dependencies
requires "nim >= 2.0.16"
requires "mummy >= 0.4.0"
requires "puppy >= 2.1.0"
requires "chronicles >= 0.10.0"
requires "yaml >= 2.0.0"
requires "tiny_sqlite >= 0.2.0"
requires "zippy >= 0.10.0"
requires "https://github.com/elcritch/atlas#package-cache-tweaks"

feature "frontend":
  requires "karax"

when fileExists("config.nims"):
  include "config.nims"

