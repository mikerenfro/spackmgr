#set -e # exit on any non-zero exit code

function add_if_missing() {
    grep -qFx "$1" $2 || echo "$1" >> $2
}

function remove_if_present() {
    sed -i "/$1/d" $2
}

function install_if_missing() {
    #`set +e
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
            spack load ${spec_without_deprecated}
        fi
        # unload everything to clean up for next time
        spack unload --all
    fi
#   set -e
}

function spack_install_with_args() {
    args=$@
    if [ -z "${SRUN}" ]; then
        spack install ${INSTALL_OPTS} ${args}
    else
        ${SRUN} ${DESTDIR}/bin/spack install ${INSTALL_OPTS} ${args}
    fi
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
    spack compiler find --scope site
    rm -f ~/.spack/linux/compilers.yaml
    spack compiler find --scope site
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
        #`set +e
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
#        set -e
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
                fi
            done < ${BASEDIR}/${f}
        fi
    done
}

function do_gcc_installs() {
    def_gcc=$(gcc -dumpversion)
    min_gcc=$(( ${def_gcc} + 1 ))
    max_gcc=$(echo $(spack versions -s gcc | grep '\.' | sort -nr | head -n1 | cut -d. -f1))

    # New gcc bootstrapping method to use OS-provided gcc to build latest,
    # then uninstall spack packages related to OS-provided gcc.

    # For whatever reason, it seems that gcc 13 can't be built without
    # autoconf-archive available.
    install_if_missing autoconf-archive%gcc@${def_gcc}
    spack load autoconf-archive%gcc@${def_gcc}
    # Build latest gcc with OS gcc, load it, add to available compilers list
    install_if_missing gcc@${max_gcc}%gcc@${def_gcc}
    spack load gcc@${max_gcc}%gcc@${def_gcc}
    spack compiler find --scope=site
    spack unload --all

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
    
    for v in $(seq ${max_gcc}-1 ${min_gcc}); do
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
}

function find_duplicates() {
    #`set +e
    if spack find | grep @ | grep -v / | sort | uniq -c | grep -qv ' 1 '; then
        echo "Duplicate packages/versions found:"
        spack find | sort | uniq -c | grep -v ' 1 '
    fi
#    set -e
}

usage() {
    echo "Usage: $0 tag [gcc|all]"
    echo "where: tag is a Spack Git tag"
    echo "(usually from https://github.com/spack/spack/tags (e.g., v0.19.1)"
    echo "Add the parameter 'gcc' to install all newer versions of GCC,"
    echo "or add the parameter 'all' to also install packages from"
    echo "specs-common.txt and specs-tag.txt"
    exit 1
}

function do_full_install() {
    git_clone
    populate_destination_folder
    initialize_spack
    if [ "$2" == "gcc" ]; then
        do_gcc_installs
        spack gc --yes-to-all
    elif [ "$2" == "all" ]; then
        do_gcc_installs
        do_spack_installs
        # spack gc --yes-to-all
    else
        usage
    fi
}

if [ $# -ne 2 ]; then
    usage
fi

if [ "${USE_CLUSTER}" == "1" ]; then
    # for cluster installations
    NODES=$(scontrol show partition ${CLUSTER_PARTITION} --oneline | grep -o ' Nodes=[[:graph:]]*' | cut -d= -f2)
    NODE_MINCPUS=$(scontrol show node ${NODES} --oneline | grep -o 'CfgTRES=[[:graph:]]*' | sort | grep -o 'cpu=[[:digit:]]*' | cut -d= -f2 | sort -n | uniq | head -1)
    PARTITION_MAXCPUS=$(scontrol show partition ${CLUSTER_PARTITION} --oneline | grep -o ' MaxCPUsPerNode=[[:graph:]]*' | cut -d= -f2)
    if [ ${PARTITION_MAXCPUS} == "UNLIMITED" ]; then
        MINCPUS=${NODE_MINCPUS}
    else
        MINCPUS=${PARTITION_MAXCPUS}
    fi
    CPUS_PER_TASK=$((${MINCPUS} / ${PARALLEL_INSTALLS}))
    SRUN="srun --ntasks-per-node=${PARALLEL_INSTALLS} --cpus-per-task=${CPUS_PER_TASK} --nodes=2 --account=hpcadmins --partition=${CLUSTER_PARTITION}"
    J_FLAG=${CPUS_PER_TASK}
else
    # for local installations
    MINCPUS=$(grep processor /proc/cpuinfo | wc -l)
    J_FLAG=$((${MINCPUS} / ${PARALLEL_INSTALLS}))
fi
