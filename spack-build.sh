#!/bin/bash
set -e # exit on any non-zero exit code, need to work around for install_if_missing and find_duplicates

function install_if_missing() {
    set +e
    if spack find $@ >& /dev/null; then
        echo "### $@ already installed"
    else
        echo "### Building $@"
        spack install --reuse -j16 $@
    fi
    set -e
}

function git_clone() {
    # Get latest code from git
    if [ ! -d "${CLONEDIR}/.git" ]; then
        git clone -c feature.manyFiles=true ${REMOTEURL} ${CLONEDIR} && \
            cd ${CLONEDIR}
    else
        cd ${CLONEDIR} && git pull
    fi
}

populate_destination_folder() {
    # Populate destination folder
    if [ ! -d ${DESTDIR} ]; then
        mkdir -p ${DESTDIR}
        git archive --format=tar ${REMOTETAG} | ( cd ${DESTDIR} && tar -xf - )
        chmod -R 755 ${DESTDIR}
    fi

    # Copy local files to site-specific folder
    cp -a ${BASEDIR}/{modules,packages}.yaml ${DESTDIR}/etc/spack/
}

function initialize_spack() {
    # Initialize new spack install, clean cache
    . ${DESTDIR}/share/spack/setup-env.sh
    spack clean --misc-cache

    # Move to source folder (for NAMD, mostly) and find new packages to build
    cd ${BASEDIR}/sources
}

do_cpu_spack_installs() {
    while IFS= read -r spec ; do
        if [ -n "${spec}" ]; then
            install_if_missing ${spec}
        fi
    done <<< "${CPU_SPECS_TO_BUILD}"
}

do_gpu_spack_installs() {
    while IFS= read -r spec ; do
        if [ -n "${spec}" ]; then
            for cuda_arch in 37 80; do
                new_spec=$(echo ${spec} | sed "s/__CA__/${cuda_arch}/g")
                install_if_missing ${new_spec}
            done
        fi
    done <<< "${GPU_SPECS_TO_BUILD}"
}

do_gcc_installs() {
    for v in $(seq 9 13); do
        install_if_missing gcc@${v}
        # find_duplicates
    done
    for v in $(seq 9 13); do
        spack load gcc@${v}
    done
    spack compiler find --scope site
    rm -f /root/.spack/linux/compilers.yaml
    spack unload --all
    spack compiler find --scope site
}

find_duplicates() {
    set +e
    spack find | sort | uniq -c | grep -v ' 1 ' >& /dev/null
    if [ $? -ne 1 ]; then
        echo "Duplicate packages/versions found:"
        spack find | sort | uniq -c | grep -v ' 1 '
    else
        echo "No duplicates found"
    fi
    set -e
}

# Enter specs to build, one per line
CPU_SPECS_TO_BUILD='
openmpi@4.1.4+legacylaunchers fabrics=ucx schedulers=slurm ^ucx+verbs+rc+dc+ud+rdmacm
maker ^perl-dbd-mysql ^mysql@5.7 ^autoconf-archive
r-tidyverse
r-brms
'

GPU_SPECS_TO_BUILD='
py-tensorflow@2.8+cuda cuda_arch=__CA__
py-tensorflow@2.9+cuda cuda_arch=__CA__
py-tensorflow@2.10+cuda cuda_arch=__CA__
py-tensorflow@2.11+cuda cuda_arch=__CA__
py-tensorflow@2.12+cuda cuda_arch=__CA__
'

if [ $# -lt 1 ]; then
    echo "Usage: $0 tag"
    echo "where: tag is a Spack Git tag"
    echo "(usually from https://github.com/spack/spack/tags (e.g., v0.19.1)"
    exit 1
fi

REMOTEURL='https://github.com/spack/spack.git'
REMOTETAG=$1
BASEDIR=$(dirname $(realpath $0))
CLONEDIR=${BASEDIR}/git
DESTDIR=${BASEDIR}/$(basename ${REMOTETAG})

git_clone
populate_destination_folder
initialize_spack
do_gcc_installs
do_cpu_spack_installs
do_gpu_spack_installs
