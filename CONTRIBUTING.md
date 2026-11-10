# Contributing

Pull requests are welcome. Please read `AGENTS.md` and preserve the zero-dependency monitored-VM design.

Run `sh tests/run_all.sh` (and `--docker` when you touch the collector) before submitting a PR. Add a regression test for every behaviour change. Do not add real logs or environment-specific Azure resources to tests. Include a note describing whether the change was validated on an actual JVM/Azure workspace or only with synthetic data.

This project uses MIT licensing for contributions, subject to your permission to submit the code. Please open an issue with a minimal sanitized reproduction rather than attaching private heap dumps or application logs.
