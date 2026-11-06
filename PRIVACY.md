# Privacy

OpenComputer itself has no network client, telemetry, account, cloud storage, or analytics. Its stdio connection returns data to the program that launched it.

App discovery returns running regular app names, bundle IDs, and PIDs. Observation returns accessibility text and metadata from an allowed app. Screenshots return selected-window PNGs. These can contain personal information. Secure accessibility field values are redacted; this does not redact pixels or ordinary fields containing secrets.

Your AI client may transmit this output to its provider. Review that client's policies and allow only apps needed for the task. OpenComputer never reads AI credentials. The optional benchmark runner reuses the installed AI clients' login flows and stores their results locally; those clients perform authentication and inference.

The runtime does not persist screenshots or accessibility trees. The benchmark audit proxy records tool names, elapsed times, and success/error status only. Benchmark transcripts and client configuration can contain private data and remain in ignored `work/` directories. Only manually reviewed aggregate results and the synthetic test fixture image are included in the repository.

Stopping the server ends access. Remove its client configuration and revoke macOS permissions to disable future use. There is no background service or login item.
