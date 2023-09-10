# spackmgr scripts

Spack software packaging scripts and configurations.

## TL;DR

`mkdir -p /path/to/spack_parent; cd /path/to/spack_parent ; /path/to/spackmgr/build v0.20.1 gcc`

## Usage

`/path/to/spackmgr/build release_tag [gcc|all]`, where `release_tag` is any valid [Spack Git tag](https://github.com/spack/spack/tags).

## Overview of files

### README.md

This file.

### Vagrantfile

Rules for building a Rocky 8 VM with minimum Spack dependencies via Vagrant.
Can also install Slurm from EPEL to more closely emulate an HPC environment.

### bisect-installing-spec

Pass/fail script for [`git bisect`](https://stackoverflow.com/a/22592593/943299), intended to identify where a regression bug might have occurred for installing a particular spec.
Can be adapted to other purposes.

### build

Bootstrapping script for Spack installations.
Intended to be run from a folder that will be the parent of the Spack installation.
1. Clones the official Spack repository into a `git` folder, then runs `git archive` against a given release tag to create the Spack root for this version.
2. Copies updated package recipies from a `package-fixes` subfolder for that release tag.
3. If Slurm is installed, adds it as an external package.
4. Optionally, does `spack` installations of every newer major release of `gcc`, adds them to the `spack compiler` list, and uses older compiler versions by default.
5. Optionally, does `spack` installations of all specs listed in `specs.txt`.

### package-fixes

A directory tree of updated files to be copied into the `var/spack/repos/builtin/packages` folder.

### shdotenv

Copy of [`shdotenv` 0.13.0](https://github.com/ko1nksm/shdotenv/releases/tag/v0.13.0), for use with `spackify`.

### sources

Placeholder folder for third-party source code (NAMD, Maker, etc.).

### spackify

Script run with `sudo` delegating Spack software management to research software engineers.

### specs.txt

List of `spack` specs to install.

## Chaining a user-managed Spack installation from a centrally-managed one

Given a centrally-managed Spack 0.20.1 in `/opt/ohpc/pub/spack/v0.20.1`, a user can leverage its packages and add their own packages in `~/spack-0.20.1` as follows:

Download and extract Spack, then disable centrally-managed Spack:
```
cd ~
wget https://github.com/spack/spack/releases/download/v0.20.1/spack-0.20.1.tar.gz
tar -zxf ~/spack-0.20.1.tar.gz
echo 'export DISABLE_SYSTEM_SPACK=1' > ~/.spack_setup
```

Copy over some standard settings from the centrally-managed Spack:
```
cp -a /opt/ohpc/pub/spack/v0.20.1/etc/spack/{linux,*.yaml} ~/spack-0.20.1/etc/spack/
```

Then, log out from the HPC completely to ensure the centrally-managed Spack is disabled entirely, and log back in.

Verify the centrally-managed Spack is no longer used by default:

```
[renfro@gpunode003(job 174321) ~]$ which spack
/usr/bin/which: no spack in (/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/home/tntech.edu/renfro/.local/bin:/home/tntech.edu/renfro/bin)
```

Load the user-managed Spack and verify it has no packages installed:
```
[renfro@gpunode003(job 174321) ~]$ . ~/spack-0.20.1/share/spack/setup-env.sh
[renfro@gpunode003(job 174321) ~]$ spack find
==> 0 installed packages
```

Add a configuration file telling the user-managed Spack where the centrally-managed Spack installation is. `nano ~/spack-0.20.1/etc/spack/upstreams.yaml` and only use the lines below:

```
upstreams:
  tntech:
    install_tree: /opt/ohpc/pub/spack/v0.20.1/opt/spack
```

Install a simple package, notice that all of this package's dependencies are already installed in the centrally-managed Spack, ensuring a much faster installation process.

```
[renfro@gpunode003(job 174321) ~]$ spack install cowsay
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/berkeley-db-18.1.40-hcm2ou2qqv7hksdgjx5s7wmoj577j3ri
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/bzip2-1.0.8-kqtusqz7a7tb6a4whcskjrc2dunjf3dr
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/ncurses-6.4-ilr5tjzk5pejy6kh25y7mczao23k3udj
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/zlib-1.2.13-s7zi7mma2xpws2mdh27j2qgnasg7uyb2
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/readline-8.2-b3k5lzac2mx2tdh7znkzpxofldi3z7rp
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/gdbm-1.23-rzxic7syszaantjc7mihxulc3eymh324
[+] /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/perl-5.36.0-im5hi7njqvu5jr3pocaq5pru3smqmb4r
==> Installing cowsay-3.04-jxz7d5p4iw5byfvba7f4e2nnenrdaxq2
==> No binary for cowsay-3.04-jxz7d5p4iw5byfvba7f4e2nnenrdaxq2 found: installing from source
==> Using cached archive: /home/tntech.edu/renfro/spack-0.20.1/var/spack/cache/_source-cache/archive/d8/d8b871332cfc1f0b6c16832ecca413ca0ac14d58626491a6733829e3d655878b.tar.gz
==> No patches needed for cowsay
==> cowsay: Executing phase: 'install'
==> cowsay: Successfully installed cowsay-3.04-jxz7d5p4iw5byfvba7f4e2nnenrdaxq2
  Stage: 0.03s.  Install: 0.15s.  Post-install: 0.12s.  Total: 0.46s
[+] /home/tntech.edu/renfro/spack-0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/cowsay-3.04-jxz7d5p4iw5byfvba7f4e2nnenrdaxq2
```

Verify where packages are installed. One is in the user-managed Spack installation, the other is in the centrally-managed Spack installation:

```
[renfro@gpunode003(job 174321) ~]$ spack find -p cowsay perl
-- linux-rocky8-x86_64_v3 / gcc@8.5.0 ---------------------------
cowsay@3.04  /home/tntech.edu/renfro/spack-0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/cowsay-3.04-jxz7d5p4iw5byfvba7f4e2nnenrdaxq2
perl@5.36.0  /opt/ohpc/pub/spack/v0.20.1/opt/spack/linux-rocky8-x86_64_v3/gcc-8.5.0/perl-5.36.0-im5hi7njqvu5jr3pocaq5pru3smqmb4r
==> 2 installed packages
```
