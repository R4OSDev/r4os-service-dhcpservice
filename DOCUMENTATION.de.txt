DHCPSVC.R4X
===========

DHCPSVC.R4X ist der DHCP-Lease-Service.

Projektstruktur seit 0.51.19:
- `build.zig` baut den Service als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, Imports, Startdaten und Contract.

Build:

    cd Code\System\Services\DhcpService
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Services\DhcpService\zig-out\DHCPSVC.R4X

Contract:
- R4XStart-Entry: `dhcpsvc_main`
- App-Klasse: `service`
- R4L-Imports: `R4SYS`, `R4NET`
- Service-Name: `DHCPSVC`
- Standardargumente: `/RUN`
- Zielpfad im Image: `C:\R4OS\SERVICES\DHCPSVC.R4X`

