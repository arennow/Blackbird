---
name: ubuntu-vm
description: Connect to and run commands on a local Ubuntu VM via SSH. USE FOR: running commands on Linux, testing Linux-specific behavior, cross-platform verification. The VM may not always be running — wait to be told it's up, or ask the user before attempting to connect.
---

# Ubuntu VM

A local Ubuntu VM is accessible via `ssh ubuntuvm`. Swift and swiftly are installed on it.

## Before connecting

The VM is not always running. Do not attempt to connect without confirmation. Either:
- Wait until the user tells you the VM is running, or
- Ask the user whether the VM is up before trying to connect

## Path mapping

The local machine's `/Users/aaron/` is mounted on the VM at `/media/psf/Home/`. Use this
mapping when referencing files that exist on the local machine from within the VM, or vice versa.

For example, if you need to run a command on the VM against this project:
```
ssh ubuntuvm "cd /media/psf/Home/code/swift/Ironbird && swift test"
```

## Avoiding conflicts

Do not run commands locally and on the VM at the same time. They share the same files via the
mount, so concurrent operations (builds, test runs, file writes) can conflict with each other.
Finish any local operations before starting VM operations, and vice versa.
