# SimpleSSD Migration Provenance

This repository is the flat development tree created from the existing SimpleSSD work.

## Source repositories

- Standalone wrapper source: `SimpleSSD-Standalone`, branch `my-modifications`
- Wrapper source commit at migration start: `3938058d85324fc9d54137ce874f37f2e65180ea`
- Embedded SimpleSSD fork source: `SimpleSSD-Standalone/simplessd`, branch `my-modifications`
- Embedded fork source commit at migration start: `a387a4a043ed019bcb07ccf7ea3ce258308258d7`
- Embedded fork upstream base: `2be371619a6533821741540ee2d8ce742c2dad2`
- McPAT source commit at migration start: `c0516bd580d344808f360bf6ae22e98b031dae67`

The embedded fork history was rewritten only to place its files under the existing
`simplessd/` directory. Authors, timestamps, messages, and file history were retained.
The rewritten fork history was then merged with the standalone wrapper history.

## Migration commits

- `Prepare flat repository for embedded simplessd`: removes the outer gitlink and `.gitmodules`.
- `Import simplessd fork history`: merges the prefixed embedded fork history.
- `Vendor McPAT dependency`: replaces the McPAT gitlink with tracked source files and removes nested submodule metadata.

## Rollback archives

Rollback bundles were created before migration in:

`/home/mohsin/SimpleSSD-migration-backup/`

They contain the outer wrapper repository, the embedded SimpleSSD fork, and McPAT.
Their SHA-256 checksums are recorded in the migration session log and should be kept
with the original nested repositories.

## Remotes

No publishing remote is configured for this staging repository. A new GitHub remote
should be added only after build, test, data, and history validation are complete.
