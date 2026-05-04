
--path:"$nim"

task frontend, "Build frontend assets":
  when not defined(feature.nsheep.frontend):
    exec "nimble install karax -d -y"

  exec "mkdir -p public"
  exec "nim js -d:release -o:public/app.js frontend/app.nim"
  exec "cp frontend/index.html public/"
  exec "cp frontend/app.css public/"
  exec "cp frontend/robot.svg public/"
  exec "cp frontend/theme.js public/"

task test, "Run tests":
  exec "nim c -r tests/test_tags.nim"
  exec "nim c -r tests/test_nimble_parse.nim"
  exec "nim c -r tests/test_parse_repo_url.nim"
  exec "nim c -r tests/test_gitea.nim"

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
