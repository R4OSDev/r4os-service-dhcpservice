# DHCPSVC.R4X

`DHCPSVC.R4X` is an independent R4OS service implemented in Zig.

## Package

- Version: `0.1.6`
- Image target: `/R4OS/SERVICES/DHCPSVC.R4X`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.


DHCPSVC reads the existing structured kernel DHCP IPC status, including lease
elapsed/remaining times. Restarting the service no longer invents a new lease
start time. The raw status API and service response layouts remain unchanged.
The existing local status self-test uses an already aged lease.

API-Migration 0.90.60
--------------------
Der normale SDK197-Bau verwendet r4os-zig-generation2, App2 und R4XStart2:2.
Platformimporte sind Query2:2; die eigenen Daten- und Netzwerkprotokolle
behalten ihre unabhaengigen Revisionen. Die Provideridentitaet und interne
Service-/Protokollaufrufe beziehen sich auf den wirklichen Startkontext;
fehlende neue Funktionen wechseln nicht auf einen alten Plattformpfad.
Endpointregistrierung und Clientstart/-open verwenden gemeinsame Clockbudgets
einschliesslich Callback-/Schedulerzeit. Der Argumentcursor erhaelt die
bisherigen Leerzeichen-/Tab-/Grosskleinschreibungsregeln ohne Quotegrammatik;
ungueltiges UTF8/Steuerzeichen und mehr als256Bytes werden definiert abgewiesen.
Die bisherigen originalen Selbsttestkoerper, Wire-/Lease-/Owner-/Generation-
und Teilresultatregeln bleiben erhalten. Readiness/Timeout ist keine echte
Release-/Rueckgabequittung. Die Besitzer von Socket, Resolverpages und
Transportressourcen werden durch diese Verbrauchermigration nicht ersetzt.
Quellen, Normalbau, Laufzeitumfang und Grenzen: Research/API-ABI/Migration/
0.90.60/Abnahme.json im lokalen Workspace; Projektbericht unter Docs/API/.
