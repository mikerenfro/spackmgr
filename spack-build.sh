#!/bin/bash
set -e # exit on any error

# Enter specs to build, one per line
SPACK_SPECS_TO_BUILD='
gcc
openmpi@4.1.4+legacylaunchers fabrics=ucx schedulers=slurm ^ucx+verbs+rc+dc+ud+rdmacm
anaconda3
miniconda3
py-pip
py-keras
py-scikit-learn
py-jupyter
opencv+python3+cudnn cuda_arch=80
namd+cuda cuda_arch=80 ^charmpp backend=multicore
namd~cuda
trinity
siesta
maker
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

# Get latest code from git
if [ ! -d "${CLONEDIR}/.git" ]; then
    git clone -c feature.manyFiles=true ${REMOTEURL} ${CLONEDIR} && cd ${CLONEDIR}
else
    cd ${CLONEDIR} && git pull
fi

# Populate destination folder
if [ ! -d ${DESTDIR} ]; then
    mkdir -p ${DESTDIR}
    git archive --format=tar ${REMOTETAG} | ( cd ${DESTDIR} && tar -xf - )
    chmod -R 755 ${DESTDIR}
fi

# Copy local files to site-specific folder
cp -a ${BASEDIR}/linux ${BASEDIR}/*.yaml ${DESTDIR}/etc/spack/

# Initialize new spack install, clean cache
. ${DESTDIR}/share/spack/setup-env.sh
spack clean --misc-cache

# Move to source folder (for NAMD, mostly) and find new packages to build
cd ${BASEDIR}/sources
while IFS= read -r spec ; do
    if [ -n "${spec}" ]; then
        if spack find ${spec} >& /dev/null; then
            echo "### ${spec} already installed"
        else
            echo "### Building ${spec}"
            spack install -j16 ${spec}
        fi
    fi
done <<< "${SPACK_SPECS_TO_BUILD}"
