# SwiftTerm terminal renderer

Unmodified Swift runtime sources from [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), tag **v1.11.2**, commit `b1262db5b6bea699a8260a8c66999436c508ca56` (MIT license).

Vendored for offline Swift 6.3.3 builds. The renderer is compiled in its upstream Swift 5 language mode. The server uses TerminalView; PTY lifecycle and input ownership belong to BLEServerKit/LinkServerKit, not SwiftTerm LocalProcess. No generator, package resolution, or network access is needed at build time.
