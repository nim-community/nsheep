import std/tables
import unittest
import nsheep/ingest

suite "parseNimbleSimple":
  test "extracts fields with equals sign":
    let content = """
name = "mypackage"
version = "1.0.0"
author = "John Doe"
description = "A great package"
license = "MIT"
"""
    let result = parseNimbleSimple(content)
    check result["name"] == "mypackage"
    check result["version"] == "1.0.0"
    check result["author"] == "John Doe"
    check result["description"] == "A great package"
    check result["license"] == "MIT"

  test "handles mixed spacing and tabs":
    let content = "name\t=\t\"mypackage\"\n  version   =   \"3.0.0\"\nauthor= \"John\""
    let result = parseNimbleSimple(content)
    check result["name"] == "mypackage"
    check result["version"] == "3.0.0"
    check result["author"] == "John"

  test "ignores comments and unrelated lines":
    let content = """
# Package info
name = "mypackage"

# Version
version = "1.0.0"

requires "nim >= 1.6.0"

author = "John Doe"
"""
    let result = parseNimbleSimple(content)
    check result["name"] == "mypackage"
    check result["version"] == "1.0.0"
    check result["author"] == "John Doe"
    check result.len == 3

  test "returns empty table for missing fields":
    let content = ""
    let result = parseNimbleSimple(content)
    check result.len == 0

  test "ignores fields without quoted values":
    let content = """
name = mypackage
version = 1.0.0
author = "John Doe"
"""
    let result = parseNimbleSimple(content)
    check result["author"] == "John Doe"
    check not result.hasKey("name")
    check not result.hasKey("version")

  test "handles empty quoted values":
    let content = """
name = ""
version = "1.0.0"
"""
    let result = parseNimbleSimple(content)
    check not result.hasKey("name")
    check result["version"] == "1.0.0"

  test "does not support deprecated call-style metadata":
    let content = """
name "mypackage"
version "2.0.0"
"""
    let result = parseNimbleSimple(content)
    check not result.hasKey("name")
    check not result.hasKey("version")

  test "extracts backend and detects bin assignment":
    let content = """
backend = "cpp"
bin = @["tool"]
"""
    let result = parseNimbleSimple(content)
    check result["backend"] == "cpp"
    check result["hasBin"] == "true"
