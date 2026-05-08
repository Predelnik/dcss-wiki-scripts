# update-from-yaml 

Lua script for updating wiki tables for dungeon crawl stone soup in lua format.

Requires generation of game data in lua format via `wiki` utility, currently existing in my fork of the game's repo.
0.34: [Link](https://github.com/Predelnik/crawl/tree/0.34-wiki)

Some notes about `wiki` utility:
* It's very similar to in-game `monster` utility, it exists as a separate file replacing game's main.
* Currently only monsters are supported
* Many things about monster data generation are taken directly from `monster` utility or inspired by it.
* YAML format was chosen because it doesn't require any special library or code to print, just proper indentation.

Usage:

First copy existing monsters table to file monster/Table_of_monsters.lua
```
<crawl-source-path>/wiki monsters > monster/mon.yaml
cd update-from-yaml
lua update-from-yaml.lua ../monster/mon.yaml ../Table_of_monsters.lua --spec ../monster/mon-spec.yaml -o ../monster\Table_of_monsters_new.lua > log.txt
```

Log about changes is very detailed. Note that even without line in log some things might get updated such as formatting or order of monsters which becomes alphabetical.


Additional option `--transfer-type`:
* Default (skip_small) - changes to numbers which less than 1% and string whitespace only changes will be ignored
* All - everything will be updated, including small changes
* Ask - ask about each change should it be transferred.
