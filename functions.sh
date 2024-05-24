set -e # exit on any non-zero exit code

function add_if_missing() {
    grep -qFx "$1" $2 || echo "$1" >> $2
}

function remove_if_present() {
    sed -i "/$1/d" $2
}

function install_if_missing() {
    set +e
    spec_to_install=""
    only_deps=0
    if echo "$@" | grep -q -- "--only dependencies"; then
        # we have a request to only check/install dependencies, not the
        # top-level package
        only_deps=1
        spec_without_only_deps=$(echo "$@" | sed 's/--only dependencies//g')
        toplevel_deps=$(${BASEDIR}/get_toplevel_deps ${spec_without_only_deps})
        for dep_hash in ${toplevel_deps}; do
            if spack find ${dep_hash} >& /dev/null; then
                # top-level dependency package found, go on to next
                :
            else
                # top-level dependency package not found, flag overall spec
                # for installation
                spec_to_install=$@
                break
            fi
        done
        if [ "${spec_to_install}" == "" ]; then
            echo "### $@ already installed"
        fi
    else
        # we have a request to check/install a package and its dependencies
        if spack find $@ >& /dev/null; then
            echo "### $@ already installed"
        else
            spec_to_install=$@
        fi
    fi
    if [ "${spec_to_install}" != "" ]; then
        # install the spec
        echo "### Installing ${spec_to_install}"
        spack_install_with_args ${spec_to_install}
        # load the spec to create directories and prevent future "permission
        # denied" errors.
        if [ ${only_deps} -eq 1 ]; then
            spack load ${toplevel_deps}
            spack mark -e ${toplevel_deps}
        else
            spec_without_deprecated=$(echo "${spec_to_install}" | sed 's/--deprecated//g')
            echo loading ${spec_without_deprecated}
            spack load ${spec_without_deprecated}
        fi
        # unload everything to clean up for next time
        spack unload --all
        echo unloaded all packages
    fi
  set -e
}

function spack_install_with_args() {
    args=$@
    set -e
    if [ -z "${SRUN}" ]; then
        spack install ${INSTALL_OPTS} ${args}
    else
        ${SRUN} ${DESTDIR}/bin/spack install ${INSTALL_OPTS} ${args}
        echo return code from srun is $?
    fi
    set +e
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

function populate_destination_folder() {
    # Populate destination folder
    if [ ! -d ${DESTDIR} ]; then
        mkdir -p ${DESTDIR}
        git archive --format=tar ${REMOTETAG} | ( cd ${DESTDIR} && tar -xf - )
        chmod -R 755 ${DESTDIR}
    fi
}

function initialize_spack() {
    # Initialize new spack install, clean cache
    . ${DESTDIR}/share/spack/setup-env.sh
    spack clean --misc-cache
    if [ -d ${BASEDIR}/package-fixes/${REMOTETAG} ]; then
        if [ ! -z "$(ls -A ${BASEDIR}/package-fixes/${REMOTETAG})" ]; then
            cp -av ${BASEDIR}/package-fixes/${REMOTETAG}/* \
                ${DESTDIR}/var/spack/repos/builtin/packages/
        fi
    fi
    # Move to source folder (for NAMD, mostly) and bootstrap compiler/package settings
    cd ${BASEDIR}/sources
    if [ ! -f ${BASEDIR}/etc/spack/compilers.yaml ]; then
        spack compiler find --scope site
        rm -f ~/.spack/linux/compilers.yaml
        spack compiler find --scope site
    fi
    if [ "${REMOTETAG}" \> "v0.21.0" ]; then
        if [ ! -f ${DESTDIR}/etc/spack/concretizer.yaml ]; then
            cat >> ${DESTDIR}/etc/spack/concretizer.yaml <<EOD
concretizer:
  reuse: true
  duplicates:
    strategy: none
EOD
        fi
    fi
    if [ ! -f ${DESTDIR}/etc/spack/packages.yaml ]; then
        echo "packages:" > ${DESTDIR}/etc/spack/packages.yaml
        set +e
        if command -v sinfo > /dev/null; then
            slurm_version=$(sinfo --version | awk '{print $NF}')
            slurm_prefix=$(dirname $(dirname $(which sinfo)))
            cat >> ${DESTDIR}/etc/spack/packages.yaml <<EOD
  slurm:
    externals:
    - spec: slurm@${slurm_version}
      prefix: ${slurm_prefix}
    buildable: False
EOD
        fi
        if rpm -q pmix-ohpc > /dev/null; then
            pmix_version=$(rpm -q --qf '%{VERSION}' pmix-ohpc)
            cat >> ${DESTDIR}/etc/spack/packages.yaml <<EOD
  pmix:
    externals:
    - spec: pmix@${pmix_version}
      prefix: /opt/ohpc/admin/pmix/
    buildable: False
EOD
        fi
        if rpm -q libevent-devel > /dev/null; then
            libevent_version=$(rpm -q --qf '%{VERSION}' libevent-devel)
            cat >> ${DESTDIR}/etc/spack/packages.yaml <<EOD
  libevent:
    externals:
    - spec: libevent@${libevent_version}
      prefix: /usr
    buildable: False
EOD
        fi
        set -e
        cat >> ${DESTDIR}/etc/spack/packages.yaml <<EOD
  all:
    target: ['x86_64_v3']
EOD
    fi
}

function do_spack_installs() {
    for f in specs-common.txt specs-${REMOTETAG}.txt; do
        if [ -f ${BASEDIR}/${f} ]; then
            while IFS= read -r spec ; do
                if [ -n "${spec}" ]; then
                    set +e
                    if echo "${spec}" | grep -qv '^#' ; then
                        if echo ${spec} | grep -q __CA__; then
                            new_spec=$(echo ${spec} | sed "s/__CA__/${CUDA_ARCH}/g")
                            #echo ${new_spec}
                            install_if_missing ${new_spec}
                        else
                            #echo ${spec}
                            install_if_missing ${spec}
                        fi
                        # find_duplicates
                    fi
                    # install_if_missing will always go back to set -e. no need for it here.
                fi
            done < ${BASEDIR}/${f}
        fi
    done
}

function do_gcc_installs() {
    def_gcc=$(gcc -dumpversion)
    min_gcc=$(( ${def_gcc} + 1 ))
    max_gcc=${MAX_GCC:-$(echo $(spack versions -s gcc | grep '\.' | sort -nr | head -n1 | cut -d. -f1))}

    # New gcc bootstrapping method to use OS-provided gcc to build latest,
    # then uninstall spack packages related to OS-provided gcc.

    if spack find gcc@${min_gcc}%gcc@${max_gcc} >& /dev/null; then
        echo "### gcc@${min_gcc}%gcc@${max_gcc} already installed, gcc bootstrapping must be done"
    else
        if spack find gcc@${max_gcc}%gcc@${def_gcc} >& /dev/null; then
            echo "### gcc@${max_gcc}%gcc@${def_gcc} already installed, bootstrapping past OS gcc must be done"
        else
            # For whatever reason, it seems that gcc 13 can't be built without
            # autoconf-archive available.
            install_if_missing autoconf-archive%gcc@${def_gcc}
            spack load autoconf-archive%gcc@${def_gcc}
            # Build latest gcc with OS gcc, load it, add to available compilers list
            install_if_missing gcc@${max_gcc}%gcc@${def_gcc}
            spack load gcc@${max_gcc}%gcc@${def_gcc}
            spack compiler find --scope=site
            spack unload --all
            # initial garbage collect (among other things) removes perl still
            # referred to gcc 8. A new perl can be built from later gcc when needed.
            spack gc --yes-to-all
        fi
        if spack find gcc@${max_gcc}%gcc@${max_gcc} >& /dev/null; then
            echo "### gcc@${max_gcc}%gcc@${max_gcc} already installed, ready to build everything else with it"
        else
            # Rebuild latest gcc from scratch with latest gcc
            spack_install_with_args --fresh gcc@${max_gcc}%gcc@${max_gcc}
            # Load the latest-latest gcc, remove previous latest gcc from available
            # compilers list, add latest-latest to available compilers list.
            spack load gcc@${max_gcc}%gcc@${max_gcc}
            spack compiler rm gcc@${max_gcc}
            spack compiler find --scope=site
            spack unload --all
            # Uninstall all packages built with OS gcc
            spack uninstall --all --yes-to-all %gcc@${def_gcc}
        fi

        # Install other gcc versions using latest gcc
        for v in $(seq $((${max_gcc} - 1)) -1 ${min_gcc}); do
            install_if_missing gcc@${v}%gcc@${max_gcc}
        done
        for v in $(seq ${min_gcc} ${max_gcc}); do
            spack load gcc@${v}%gcc@${max_gcc}
        done
        spack compiler find --scope site # to find other spack-installed gccs
        rm -f ~/.spack/linux/compilers.yaml
        spack unload --all
        spack compiler find --scope site # to find OS-installed gcc
        # Add all available gcc versions to require, preferring later versions
        # wherever possible.
        ONE_OF=$(spack compiler list --scope site | grep @ | sort -t@ -k2 -nr | sed "s/^/'%/g;s/$/'/g" | paste -s -d,)
        add_if_missing    "    require:" ${DESTDIR}/etc/spack/packages.yaml
        remove_if_present '    - one_of:' ${DESTDIR}/etc/spack/packages.yaml
        add_if_missing    "    - one_of: [${ONE_OF}]" ${DESTDIR}/etc/spack/packages.yaml
    fi
}

function find_duplicates() {
    set +e
    if spack find | grep @ | grep -v / | sort | uniq -c | grep -qv ' 1 '; then
        echo "Duplicate packages/versions found:"
        spack find | sort | uniq -c | grep -v ' 1 '
    fi
    set -e
}

usage() {
    echo "Usage: $0 tag [gcc|all|none]"
    echo "where: tag is a Spack Git tag"
    echo "(usually from https://github.com/spack/spack/tags (e.g., v0.19.1)"
    echo "Add the parameter 'gcc' to install all newer versions of GCC,"
    echo "add the parameter 'all' to also install packages from"
    echo "specs-common.txt and specs-tag.txt, or add the parameter 'none'"
    echo "to install nothing at all."
    exit 1
}

function do_full_install() {
    git_clone
    populate_destination_folder
    initialize_spack
    if [ "$2" == "gcc" ]; then
        do_gcc_installs
        # spack gc --yes-to-all
    elif [ "$2" == "all" ]; then
        do_gcc_installs
        do_spack_installs
        # spack gc --yes-to-all
    elif [ "$2" == "none" ]; then
        :
    else
        usage
    fi
}

if [ $# -ne 2 ]; then
    usage
fi

if [ "${USE_CLUSTER}" == "1" ]; then
    # for cluster installations
    PARTITION_NODES=$(scontrol show partition ${CLUSTER_PARTITION} --oneline | grep -o ' Nodes=[[:graph:]]*' | cut -d= -f2)
    NODE_MINCPUS=$(scontrol show node ${PARTITION_NODES} --oneline | grep -o 'CfgTRES=[[:graph:]]*' | sort | grep -o 'cpu=[[:digit:]]*' | cut -d= -f2 | sort -n | uniq | head -1)
    PARTITION_MAXCPUS=$(scontrol show partition ${CLUSTER_PARTITION} --oneline | grep -o ' MaxCPUsPerNode=[[:graph:]]*' | cut -d= -f2)
    if [ ${PARTITION_MAXCPUS} == "UNLIMITED" ]; then
        MINCPUS=${NODE_MINCPUS}
    else
        MINCPUS=${PARTITION_MAXCPUS}
    fi
    CPUS_PER_TASK=$((${MINCPUS} / ${PARALLEL_INSTALLS}))
    if [ ! -z "${SLURM_JOB_ID}" ]; then
        # already running inside an allocation, use it.
        JOBID_FLAG="--jobid=${SLURM_JOB_ID}"
    else
        JOBID_FLAG=""
    fi
    SRUN="srun ${JOBID_FLAG} --ntasks-per-node=${PARALLEL_INSTALLS} --cpus-per-task=${CPUS_PER_TASK} --nodes=${NODES} --account=${CLUSTER_JOB_ACCOUNT} --partition=${CLUSTER_PARTITION}"
    J_FLAG=${CPUS_PER_TASK}
else
    # for local installations
    MINCPUS=$(grep processor /proc/cpuinfo | wc -l)
    J_FLAG=$((${MINCPUS} / ${PARALLEL_INSTALLS}))
fi
