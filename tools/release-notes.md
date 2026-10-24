{{languages}} interpreter firmware for Lamella {{version}}, built from [lamellaproject/lamella]({{source}}) at tag [{{tag}}]({{source}}/tree/{{tag}}).

Programs are deployed to an interpreter using Lamella {{version}}'s tools (e.g. `lamella run` or `lamella deploy`).

C# programs may also be deployed to an interpreter using .NET tools (e.g. `dotnet run`) in conjunction with the Lamella SDK (NuGet).

| Board | Image |
| --- | --- |
{{boards}}

The method for installing an interpreter onto a microcontroller varies by board. 

`SHA256SUMS` gives each file's SHA-256, and `manifest.json` carries the same. `THIRD-PARTY-NOTICES.txt` and `RUST-STANDARD-LIBRARY-NOTICES.html` list third-party software in the images and corresponding licenses.
{{radio}}
