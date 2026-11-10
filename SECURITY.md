# Security Policy

This project is a diagnostic reference implementation, not a security hardening solution.

If you discover a vulnerability, do not post live credentials, customer log files, or exploit details in a public issue. Contact the repository maintainers through a private channel, or use GitHub private vulnerability reporting if it is enabled for this repository.

Known concerns: JVM diagnostic-tool privileges, host metadata in collected logs, local output file permissions, Azure DCR/Azure Monitor RBAC, and the potentially confidential contents of unrelated GC/heap logs. Never upload raw heap dumps or production data to public repositories.
