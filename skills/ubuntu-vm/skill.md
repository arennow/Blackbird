---
name: ubuntu-vm
description: Connect to and run commands on a local Ubuntu VM via SSH. USE FOR: running commands on Linux, testing Linux-specific behavior, cross-platform verification. The VM may not always be running. Check first before trying to connect.
---

# Ubuntu VM

A local Ubuntu VM is accessible via `ssh ubuntuvm`. Swift and swiftly are installed on it.

## Before connecting

The VM is not always running. Check if it's running by pinging it:
```
ping -o ubuntuvm
```
If you get responses, it's running. If you get "unknown host" or no responses, decide whether the
changes merit asking the user to start the VM. If so, ask them to start it and wait until it's
running before proceeding.

## Swiftly configuration

Swiftly is installed, but you'll need to run
```
. "/home/parallels/.local/share/swiftly/env.sh"
```
to set up the environment variables before you can use it. You can run this command in each session, or add it to the shell profile on the VM for convenience.

## Path mapping

The local machine's `/Users/aaron/` is mounted on the VM at `/media/psf/Home/`. Use this
mapping when referencing files that exist on the local machine from within the VM, or vice versa. For example, the Ironbird code at `/Users/aaron/code/swift/Ironbird` locally is accessible at `/media/psf/Home/code/swift/Ironbird` on the VM.

## Reducing token usage

Prefer to run swift commands in quiet mode (`-q`) to reduce the amount of output and tokens used, especially for test runs. For example:
```
swift test -q
```

## Avoiding conflicts

Do not run commands locally and on the VM at the same time. They share the same files via the
mount, so concurrent operations (builds, test runs, file writes) can conflict with each other.
Finish any local operations before starting VM operations, and vice versa.
